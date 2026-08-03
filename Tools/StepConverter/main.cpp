// step-tessellate: STEP -> binary STL, for Spool's M5 STEP-import path.
//
// Standalone by design: this is invoked as a subprocess (via Process) from
// SpoolCore's slow job lane rather than linked in-process, so a crash or hang
// in OCCT can't take the app down with it, and this file can be built/tested
// independently of the Swift side entirely.
//
// Usage: step-tessellate <input.step> <output.stl>
//
// Pipeline: STEPControl_Reader -> BRepMesh_IncrementalMesh on the whole shape
// (so faces sharing an edge share that edge's discretization, rather than
// tessellating each face in isolation) -> walk every TopAbs_FACE's
// Poly_Triangulation -> weld near-coincident vertices (adjacent faces still
// don't emit bit-identical boundary points even when meshed together) ->
// drop degenerate/zero-area triangles (pole singularities on curved
// surfaces) -> write binary STL in the exact layout SpoolMesh's STLParser
// expects (80-byte header, uint32 count, 50 bytes/triangle, little-endian).
//
// The vertex weld + degenerate-triangle strip are the two cleanup passes the
// source Python/pythonocc app's CLAUDE.md build log calls out as required to
// make the watertight check trustworthy on tessellated STEP geometry.

#include <STEPControl_Reader.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS.hxx>
#include <TopExp_Explorer.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_Triangle.hxx>
#include <TopLoc_Location.hxx>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <Standard_Failure.hxx>
#include <Message.hxx>
#include <Message_Printer.hxx>
#include <Message_Messenger.hxx>

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>
#include <unordered_map>
#include <array>
#include <string>
#include <iostream>

namespace {

struct Vertex {
    float x, y, z;
};

struct Triangle {
    uint32_t a, b, c;
};

// Quantized-grid vertex welder. Coincident-enough points (within `epsilon`,
// scaled to the shape's bounding-box diagonal by the caller) collapse to one
// shared vertex. Checks the point's cell plus all 26 neighbors so a pair of
// near-duplicate points that straddle a cell boundary still merge.
class VertexWelder {
public:
    explicit VertexWelder(double epsilon) : eps_(epsilon) {}

    uint32_t weld(const gp_Pnt &p) {
        const std::array<int64_t, 3> cell = cellOf(p);
        for (int dx = -1; dx <= 1; ++dx) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dz = -1; dz <= 1; ++dz) {
                    Key k{cell[0] + dx, cell[1] + dy, cell[2] + dz};
                    auto it = buckets_.find(k);
                    if (it == buckets_.end()) continue;
                    for (uint32_t candidate : it->second) {
                        const Vertex &v = vertices_[candidate];
                        double ddx = v.x - p.X();
                        double ddy = v.y - p.Y();
                        double ddz = v.z - p.Z();
                        if (ddx * ddx + ddy * ddy + ddz * ddz <= eps_ * eps_) {
                            return candidate;
                        }
                    }
                }
            }
        }
        uint32_t index = static_cast<uint32_t>(vertices_.size());
        vertices_.push_back(Vertex{static_cast<float>(p.X()), static_cast<float>(p.Y()), static_cast<float>(p.Z())});
        buckets_[Key{cell[0], cell[1], cell[2]}].push_back(index);
        return index;
    }

    const std::vector<Vertex> &vertices() const { return vertices_; }

private:
    struct Key {
        int64_t x, y, z;
        bool operator==(const Key &o) const { return x == o.x && y == o.y && z == o.z; }
    };
    struct KeyHash {
        size_t operator()(const Key &k) const {
            size_t h = std::hash<int64_t>()(k.x);
            h ^= std::hash<int64_t>()(k.y) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
            h ^= std::hash<int64_t>()(k.z) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
            return h;
        }
    };

    std::array<int64_t, 3> cellOf(const gp_Pnt &p) const {
        return {
            static_cast<int64_t>(std::floor(p.X() / eps_)),
            static_cast<int64_t>(std::floor(p.Y() / eps_)),
            static_cast<int64_t>(std::floor(p.Z() / eps_)),
        };
    }

    double eps_;
    std::vector<Vertex> vertices_;
    std::unordered_map<Key, std::vector<uint32_t>, KeyHash> buckets_;
};

bool isDegenerate(const Vertex &a, const Vertex &b, const Vertex &c, double minAreaSq) {
    if (std::memcmp(&a, &b, sizeof(Vertex)) == 0) return true;
    if (std::memcmp(&a, &c, sizeof(Vertex)) == 0) return true;
    if (std::memcmp(&b, &c, sizeof(Vertex)) == 0) return true;
    double ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z;
    double vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z;
    double cx = uy * vz - uz * vy;
    double cy = uz * vx - ux * vz;
    double cz = ux * vy - uy * vx;
    double areaSq = (cx * cx + cy * cy + cz * cz) * 0.25;
    return areaSq < minAreaSq;
}

Vertex faceNormal(const Vertex &a, const Vertex &b, const Vertex &c) {
    double ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z;
    double vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z;
    double cx = uy * vz - uz * vy;
    double cy = uz * vx - ux * vz;
    double cz = ux * vy - uy * vx;
    double len = std::sqrt(cx * cx + cy * cy + cz * cz);
    if (len < 1e-20) return Vertex{0, 0, 0};
    return Vertex{static_cast<float>(cx / len), static_cast<float>(cy / len), static_cast<float>(cz / len)};
}

void writeLE32(std::FILE *f, uint32_t v) {
    uint8_t bytes[4] = {
        static_cast<uint8_t>(v & 0xFF), static_cast<uint8_t>((v >> 8) & 0xFF),
        static_cast<uint8_t>((v >> 16) & 0xFF), static_cast<uint8_t>((v >> 24) & 0xFF),
    };
    std::fwrite(bytes, 1, 4, f);
}

void writeLEFloat(std::FILE *f, float value) {
    uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    writeLE32(f, bits);
}

void writeLE16(std::FILE *f, uint16_t v) {
    uint8_t bytes[2] = {static_cast<uint8_t>(v & 0xFF), static_cast<uint8_t>((v >> 8) & 0xFF)};
    std::fwrite(bytes, 1, 2, f);
}

} // namespace

int main(int argc, char **argv) {
    if (argc != 3) {
        std::cerr << "usage: step-tessellate <input.step> <output.stl>\n";
        return 2;
    }
    const std::string inputPath = argv[1];
    const std::string outputPath = argv[2];

    // Silence OCCT's default stdout trace printer — we only want our own
    // stderr diagnostics, and stdout must stay clean for the parent process.
    Message::DefaultMessenger()->RemovePrinters(STANDARD_TYPE(Message_Printer));

    try {
        STEPControl_Reader reader;
        IFSelect_ReturnStatus status = reader.ReadFile(inputPath.c_str());
        if (status != IFSelect_RetDone) {
            std::cerr << "step-tessellate: failed to read STEP file (status " << static_cast<int>(status) << ")\n";
            return 1;
        }

        Standard_Integer numRoots = reader.TransferRoots();
        if (numRoots <= 0) {
            std::cerr << "step-tessellate: STEP file contained no transferable roots\n";
            return 1;
        }

        TopoDS_Shape shape = reader.OneShape();
        if (shape.IsNull()) {
            std::cerr << "step-tessellate: transferred shape is null\n";
            return 1;
        }

        Bnd_Box bbox;
        BRepBndLib::Add(shape, bbox);
        if (bbox.IsVoid()) {
            std::cerr << "step-tessellate: shape has no bounding box (empty geometry)\n";
            return 1;
        }
        double xmin, ymin, zmin, xmax, ymax, zmax;
        bbox.Get(xmin, ymin, zmin, xmax, ymax, zmax);
        double dx = xmax - xmin, dy = ymax - ymin, dz = zmax - zmin;
        double diagonal = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (diagonal < 1e-6) diagonal = 1e-6;

        // Linear deflection ~0.04% of the bounding diagonal balances thumbnail-
        // quality smoothness against triangle count for typical printable
        // parts; angular deflection uses OCCT's own default (0.5 rad).
        const double linearDeflection = diagonal * 4e-4;
        const double angularDeflection = 0.5;
        BRepMesh_IncrementalMesh mesher(shape, linearDeflection, Standard_False, angularDeflection, Standard_True);
        if (!mesher.IsDone()) {
            std::cerr << "step-tessellate: tessellation did not complete\n";
            return 1;
        }

        // Weld epsilon scaled to the same diagonal, an order of magnitude
        // tighter than the meshing deflection itself — enough to close the
        // sub-deflection gaps between independently-recorded shared-edge
        // points without merging genuinely distinct nearby geometry.
        const double weldEpsilon = diagonal * 4e-5;
        const double minTriangleAreaSq = weldEpsilon * weldEpsilon * 0.01;

        VertexWelder welder(weldEpsilon);
        std::vector<Triangle> triangles;

        for (TopExp_Explorer exp(shape, TopAbs_FACE); exp.More(); exp.Next()) {
            const TopoDS_Face &face = TopoDS::Face(exp.Current());
            TopLoc_Location loc;
            Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
            if (tri.IsNull()) continue;

            const gp_Trsf &trsf = loc.Transformation();
            bool reversed = face.Orientation() == TopAbs_REVERSED;

            std::vector<uint32_t> localToWelded(tri->NbNodes() + 1);
            for (Standard_Integer i = 1; i <= tri->NbNodes(); ++i) {
                gp_Pnt p = tri->Node(i);
                p.Transform(trsf);
                localToWelded[i] = welder.weld(p);
            }

            for (Standard_Integer i = 1; i <= tri->NbTriangles(); ++i) {
                Standard_Integer n1, n2, n3;
                tri->Triangle(i).Get(n1, n2, n3);
                uint32_t a = localToWelded[n1];
                uint32_t b = localToWelded[n2];
                uint32_t c = localToWelded[n3];
                if (reversed) std::swap(b, c);
                triangles.push_back(Triangle{a, b, c});
            }
        }

        if (triangles.empty()) {
            std::cerr << "step-tessellate: no triangles produced (no faces tessellated)\n";
            return 3;
        }

        const std::vector<Vertex> &vertices = welder.vertices();
        std::vector<Triangle> kept;
        kept.reserve(triangles.size());
        for (const Triangle &t : triangles) {
            if (isDegenerate(vertices[t.a], vertices[t.b], vertices[t.c], minTriangleAreaSq)) continue;
            kept.push_back(t);
        }

        if (kept.empty()) {
            std::cerr << "step-tessellate: all triangles were degenerate after cleanup\n";
            return 3;
        }

        std::FILE *out = std::fopen(outputPath.c_str(), "wb");
        if (!out) {
            std::cerr << "step-tessellate: could not open output path for writing\n";
            return 1;
        }

        char header[80] = {0};
        std::snprintf(header, sizeof(header), "spool step-tessellate output");
        std::fwrite(header, 1, 80, out);
        writeLE32(out, static_cast<uint32_t>(kept.size()));

        for (const Triangle &t : kept) {
            const Vertex &a = vertices[t.a];
            const Vertex &b = vertices[t.b];
            const Vertex &c = vertices[t.c];
            Vertex n = faceNormal(a, b, c);
            writeLEFloat(out, n.x); writeLEFloat(out, n.y); writeLEFloat(out, n.z);
            writeLEFloat(out, a.x); writeLEFloat(out, a.y); writeLEFloat(out, a.z);
            writeLEFloat(out, b.x); writeLEFloat(out, b.y); writeLEFloat(out, b.z);
            writeLEFloat(out, c.x); writeLEFloat(out, c.y); writeLEFloat(out, c.z);
            writeLE16(out, 0);
        }
        std::fclose(out);

        std::cerr << "step-tessellate: wrote " << kept.size() << " triangles ("
                   << vertices.size() << " welded vertices) to " << outputPath << "\n";
        return 0;
    } catch (const Standard_Failure &e) {
        std::cerr << "step-tessellate: OCCT exception: " << e.GetMessageString() << "\n";
        return 1;
    } catch (const std::exception &e) {
        std::cerr << "step-tessellate: exception: " << e.what() << "\n";
        return 1;
    }
}
