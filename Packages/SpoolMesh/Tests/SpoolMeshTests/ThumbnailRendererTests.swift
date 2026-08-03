import AppKit
import Testing
@testable import SpoolMesh

@Suite struct ThumbnailRendererTests {
    @Test @MainActor func rendersCubeToCorrectlySizedNonEmptyPNG() throws {
        let mesh = MeshFixtures.unitCube()
        let pngData = try ThumbnailRenderer.renderPNG(mesh: mesh, options: .init(pixelSize: 128))

        guard let bitmap = NSBitmapImageRep(data: pngData) else {
            Issue.record("PNG data didn't decode back into an image")
            return
        }
        #expect(bitmap.pixelsWide == 128)
        #expect(bitmap.pixelsHigh == 128)

        // At least some pixel should be non-transparent — i.e. the cube was actually
        // drawn, not just an empty transparent canvas.
        var foundOpaquePixel = false
        outer: for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                    foundOpaquePixel = true
                    break outer
                }
            }
        }
        #expect(foundOpaquePixel, "expected at least one visibly-rendered pixel of the cube")
    }

    @Test @MainActor func emptyMeshThrows() {
        let mesh = TriangleMesh(vertices: [], triangles: [])
        #expect(throws: (any Error).self) {
            _ = try ThumbnailRenderer.renderPNG(mesh: mesh)
        }
    }
}
