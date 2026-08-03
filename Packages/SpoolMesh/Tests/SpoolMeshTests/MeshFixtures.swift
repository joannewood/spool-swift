@testable import SpoolMesh

/// Shared test geometry: a closed unit cube (volume = 1.0 exactly) and the same cube
/// with one face removed (an open boundary — the canonical "not watertight" case).
enum MeshFixtures {
    private static let corners: [SIMD3<Float>] = [
        [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
        [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
    ]

    // Outward-facing, consistently wound (counter-clockwise seen from outside).
    private static let allFaceTriangles: [(Int32, Int32, Int32)] = [
        (0, 3, 2), (0, 2, 1), // bottom (normal -z)
        (4, 5, 6), (4, 6, 7), // top (normal +z)
        (0, 1, 5), (0, 5, 4), // front (normal -y)
        (1, 2, 6), (1, 6, 5), // right (normal +x)
        (2, 3, 7), (2, 7, 6), // back (normal +y)
        (3, 0, 4), (3, 4, 7), // left (normal -x)
    ]

    static func unitCube() -> TriangleMesh {
        TriangleMesh(vertices: corners, triangles: allFaceTriangles)
    }

    static func openBox() -> TriangleMesh {
        // Drop the top face's two triangles — leaves a boundary loop, not watertight.
        TriangleMesh(vertices: corners, triangles: Array(allFaceTriangles.dropFirst(2)))
    }
}
