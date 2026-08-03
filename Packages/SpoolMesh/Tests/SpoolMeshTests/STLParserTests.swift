import Foundation
import Testing
@testable import SpoolMesh

/// Builds a real binary-STL byte buffer for a unit cube — 12 triangles (2 per face x 6
/// faces), 8 unique corners — so parser tests exercise the actual binary format rather
/// than a canned fixture file.
private func makeCubeSTLBinaryData() -> Data {
    let corners: [SIMD3<Float>] = [
        [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
        [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
    ]
    // Each face as two triangles, referencing corner indices.
    let faceTriangles: [(Int, Int, Int)] = [
        (0, 1, 2), (0, 2, 3), // bottom
        (4, 6, 5), (4, 7, 6), // top
        (0, 4, 5), (0, 5, 1), // front
        (1, 5, 6), (1, 6, 2), // right
        (2, 6, 7), (2, 7, 3), // back
        (3, 7, 4), (3, 4, 0), // left
    ]

    var data = Data(count: 80) // header, contents irrelevant
    data.append(contentsOf: withUnsafeBytes(of: UInt32(faceTriangles.count).littleEndian) { Array($0) })
    for (a, b, c) in faceTriangles {
        data.append(contentsOf: withUnsafeBytes(of: Float32(0)) { Array($0) }) // normal.x (unused by parser)
        data.append(contentsOf: withUnsafeBytes(of: Float32(0)) { Array($0) }) // normal.y
        data.append(contentsOf: withUnsafeBytes(of: Float32(0)) { Array($0) }) // normal.z
        for idx in [a, b, c] {
            let v = corners[idx]
            data.append(contentsOf: withUnsafeBytes(of: v.x) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: v.y) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: v.z) { Array($0) })
        }
        data.append(contentsOf: [0, 0]) // attribute byte count
    }
    return data
}

@Suite struct STLParserTests {
    @Test func parsesBinaryCubeWithWeldedVertices() throws {
        let mesh = try STLParser.parse(data: makeCubeSTLBinaryData())
        #expect(mesh.triangles.count == 12)
        #expect(mesh.vertices.count == 8, "8 unique corners should be welded from 36 raw triangle-vertex entries")
    }

    @Test func parsesASCIICubeEquivalently() throws {
        var text = "solid cube\n"
        let corners: [SIMD3<Float>] = [
            [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
            [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1],
        ]
        let faceTriangles: [(Int, Int, Int)] = [(0, 1, 2), (0, 2, 3)]
        for (a, b, c) in faceTriangles {
            text += "facet normal 0 0 0\nouter loop\n"
            for idx in [a, b, c] {
                let v = corners[idx]
                text += "vertex \(v.x) \(v.y) \(v.z)\n"
            }
            text += "endloop\nendfacet\n"
        }
        text += "endsolid cube\n"

        let mesh = try STLParser.parse(data: Data(text.utf8))
        #expect(mesh.triangles.count == 2)
        #expect(mesh.vertices.count == 4, "the two triangles share an edge (2 vertices), so 6 refs weld to 4")
    }

    @Test func garbageDataThrowsRatherThanCrashing() {
        #expect(throws: (any Error).self) {
            _ = try STLParser.parse(data: Data([0x01, 0x02, 0x03]))
        }
    }
}
