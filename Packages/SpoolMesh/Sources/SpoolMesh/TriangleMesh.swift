import simd

/// Format-agnostic triangle mesh — every loader (STL, OBJ, 3MF, and eventually
/// tessellated STEP) normalizes into this one type, so thumbnail rendering and mesh
/// analysis (manifold check, volume, bbox, tri-count) only need one code path
/// regardless of source format. Mirrors the role `trimesh.Trimesh` plays in the source
/// app's Python worker.
public struct TriangleMesh: Sendable {
    public var vertices: [SIMD3<Float>]
    public var triangles: [(Int32, Int32, Int32)]

    public init(vertices: [SIMD3<Float>], triangles: [(Int32, Int32, Int32)]) {
        self.vertices = vertices
        self.triangles = triangles
    }
}
