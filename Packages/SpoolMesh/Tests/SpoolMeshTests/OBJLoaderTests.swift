import Foundation
import Testing
@testable import SpoolMesh

private let cubeOBJText = """
# unit cube
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
v 0 0 1
v 1 0 1
v 1 1 1
v 0 1 1
f 1 2 3
f 1 3 4
f 5 7 6
f 5 8 7
f 1 5 6
f 1 6 2
f 2 6 7
f 2 7 3
f 3 7 8
f 3 8 4
f 4 8 5
f 4 5 1
"""

@Suite struct OBJLoaderTests {
    @Test func parsesRealOBJFileFromDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolMeshTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("cube.obj")
        try cubeOBJText.write(to: url, atomically: true, encoding: .utf8)

        let mesh = try OBJLoader.parse(url: url)
        #expect(mesh.triangles.count == 12)
        #expect(mesh.vertices.count == 8)
    }

    @Test func missingFileThrows() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).obj")
        #expect(throws: (any Error).self) {
            _ = try OBJLoader.parse(url: url)
        }
    }
}
