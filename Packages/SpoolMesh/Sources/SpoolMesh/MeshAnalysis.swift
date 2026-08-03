import Foundation

/// The geometry facts the app needs to store per file — mirrors the source app's
/// per-file columns (`bbox_x/y/z`, `volume_mm3`, `tri_count`, `is_manifold`).
public struct MeshAnalysis: Sendable, Equatable {
    public var boundingBoxMin: SIMD3<Float>
    public var boundingBoxMax: SIMD3<Float>
    /// `nil` when the mesh isn't manifold — an open/non-manifold mesh's "volume" isn't
    /// a meaningful number, so it's simply not reported rather than reporting a
    /// misleading one.
    public var volumeMm3: Double?
    public var triangleCount: Int
    public var isManifold: Bool
}

/// From-scratch, dependency-free mesh analysis operating uniformly on `TriangleMesh`
/// regardless of source format — there's no Swift equivalent of `trimesh`, so this is
/// the native replacement for its `is_watertight`/`volume`/`bounds` used by the source
/// app's worker.
public enum MeshAnalyzer {
    public static func analyze(_ mesh: TriangleMesh) -> MeshAnalysis {
        let bbox = boundingBox(mesh)
        let manifold = isWatertight(mesh)
        return MeshAnalysis(
            boundingBoxMin: bbox.min,
            boundingBoxMax: bbox.max,
            volumeMm3: manifold ? signedVolume(mesh) : nil,
            triangleCount: mesh.triangles.count,
            isManifold: manifold
        )
    }

    public static func boundingBox(_ mesh: TriangleMesh) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var minV = mesh.vertices.first else { return (.zero, .zero) }
        var maxV = minV
        for v in mesh.vertices {
            minV = SIMD3(Swift.min(minV.x, v.x), Swift.min(minV.y, v.y), Swift.min(minV.z, v.z))
            maxV = SIMD3(Swift.max(maxV.x, v.x), Swift.max(maxV.y, v.y), Swift.max(maxV.z, v.z))
        }
        return (minV, maxV)
    }

    /// A mesh is a closed, consistently-oriented 2-manifold iff every directed edge
    /// (the edges of each triangle, walked in winding order) appears exactly once, and
    /// its reverse — the same edge as seen by the adjacent triangle on the other side —
    /// also appears exactly once. A directed edge with no reverse is a boundary (a hole
    /// or a missing face); a directed edge appearing more than once means overlapping/
    /// duplicate geometry. Mirrors the source app's STEP-loader comment: this is
    /// exactly the check that a naive "each edge touched by 2 triangles" count gets
    /// wrong on independently-tessellated or duplicated geometry.
    public static func isWatertight(_ mesh: TriangleMesh) -> Bool {
        guard !mesh.triangles.isEmpty else { return false }
        var directedCounts: [DirectedEdge: Int] = [:]
        directedCounts.reserveCapacity(mesh.triangles.count * 3)
        for (a, b, c) in mesh.triangles {
            directedCounts[DirectedEdge(from: a, to: b), default: 0] += 1
            directedCounts[DirectedEdge(from: b, to: c), default: 0] += 1
            directedCounts[DirectedEdge(from: c, to: a), default: 0] += 1
        }
        for (edge, count) in directedCounts {
            guard count == 1 else { return false }
            guard directedCounts[edge.reversed] == 1 else { return false }
        }
        return true
    }

    /// Signed sum of tetrahedra volumes relative to the origin: V = (1/6)|Σ v0·(v1×v2)|.
    /// Computed in `Double` even though vertices are `Float` — the sum over many small
    /// per-triangle terms can lose precision in `Float` for meshes with thousands of
    /// triangles, matching common practice for this exact formula.
    public static func signedVolume(_ mesh: TriangleMesh) -> Double {
        var sum = 0.0
        for (ia, ib, ic) in mesh.triangles {
            let a = SIMD3<Double>(Double(mesh.vertices[Int(ia)].x), Double(mesh.vertices[Int(ia)].y), Double(mesh.vertices[Int(ia)].z))
            let b = SIMD3<Double>(Double(mesh.vertices[Int(ib)].x), Double(mesh.vertices[Int(ib)].y), Double(mesh.vertices[Int(ib)].z))
            let c = SIMD3<Double>(Double(mesh.vertices[Int(ic)].x), Double(mesh.vertices[Int(ic)].y), Double(mesh.vertices[Int(ic)].z))
            sum += dot(a, cross(b, c))
        }
        return abs(sum) / 6.0
    }

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}

struct DirectedEdge: Hashable {
    let from: Int32
    let to: Int32
    var reversed: DirectedEdge { DirectedEdge(from: to, to: from) }
}
