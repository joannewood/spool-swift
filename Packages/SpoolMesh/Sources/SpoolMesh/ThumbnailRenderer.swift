import AppKit
import Metal
import SceneKit
import simd

/// Renders a preview thumbnail with `SCNRenderer` offscreen (no window/view needed) —
/// chosen over raw Metal because the scene is trivial (one camera, one light, one
/// uniform material) and SceneKit gives that for free, and over the source app's
/// pyrender/OpenGL approach because there's no headless-EGL/Mesa driver dance to get
/// right on macOS at all. Camera placement mirrors the source app's `render.py`
/// constants exactly, so thumbnails look the same: 30° elevation, 40° azimuth, 40° FOV,
/// a 1.10 margin around the mesh's bounding sphere, transparent background.
public enum ThumbnailRenderer {
    public enum ThumbnailError: Error {
        case noMetalDevice
        case renderFailed
        case emptyMesh
    }

    public struct Options: Sendable {
        public var pixelSize: Int
        public var elevationDegrees: Float
        public var azimuthDegrees: Float
        public var fieldOfViewDegrees: Float
        public var margin: Float

        public init(
            pixelSize: Int = 512,
            elevationDegrees: Float = 30,
            azimuthDegrees: Float = 40,
            fieldOfViewDegrees: Float = 40,
            margin: Float = 1.10
        ) {
            self.pixelSize = pixelSize
            self.elevationDegrees = elevationDegrees
            self.azimuthDegrees = azimuthDegrees
            self.fieldOfViewDegrees = fieldOfViewDegrees
            self.margin = margin
        }
    }

    /// Renders a transparent-background PNG. Must run on the main thread — SceneKit's
    /// offscreen renderer is not documented as safe to drive concurrently from a
    /// background actor, so `RenderJobHandler` hops to `MainActor` for this call.
    @MainActor
    public static func renderPNG(mesh: TriangleMesh, options: Options = Options()) throws -> Data {
        guard !mesh.vertices.isEmpty, !mesh.triangles.isEmpty else { throw ThumbnailError.emptyMesh }
        guard let device = MTLCreateSystemDefaultDevice() else { throw ThumbnailError.noMetalDevice }

        let bbox = MeshAnalyzer.boundingBox(mesh)
        let center = (bbox.min + bbox.max) * 0.5
        let radius = max(simd_length(bbox.max - bbox.min) * 0.5, 0.001)

        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: makeGeometry(from: mesh)))

        let cameraNode = makeCameraNode(center: center, radius: radius, options: options)
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(makeLightNode(at: cameraNode.position, looking: center))
        scene.rootNode.addChildNode(makeAmbientLightNode())

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.isJitteringEnabled = true

        let size = CGSize(width: options.pixelSize, height: options.pixelSize)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ThumbnailError.renderFailed
        }
        return png
    }

    private static func makeGeometry(from mesh: TriangleMesh) -> SCNGeometry {
        let vertexSource = SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)) })

        var indices: [Int32] = []
        indices.reserveCapacity(mesh.triangles.count * 3)
        for (a, b, c) in mesh.triangles {
            indices.append(a)
            indices.append(b)
            indices.append(c)
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.triangles.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.70, alpha: 1.0)
        material.metalness.contents = 0.05
        material.roughness.contents = 0.85
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    private static func makeCameraNode(center: SIMD3<Float>, radius: Float, options: Options) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(options.fieldOfViewDegrees)
        camera.zNear = 0.01
        camera.zFar = Double(radius) * 20 + 100

        let fovHalfRad = Double(options.fieldOfViewDegrees) * .pi / 180 / 2
        let distance = Double(radius * options.margin) / sin(fovHalfRad)
        let elevRad = Double(options.elevationDegrees) * .pi / 180
        let azimRad = Double(options.azimuthDegrees) * .pi / 180

        let offsetX = distance * cos(elevRad) * sin(azimRad)
        let offsetY = distance * sin(elevRad)
        let offsetZ = distance * cos(elevRad) * cos(azimRad)

        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(
            CGFloat(Double(center.x) + offsetX),
            CGFloat(Double(center.y) + offsetY),
            CGFloat(Double(center.z) + offsetZ)
        )
        node.look(at: SCNVector3(CGFloat(center.x), CGFloat(center.y), CGFloat(center.z)))
        return node
    }

    private static func makeLightNode(at position: SCNVector3, looking target: SIMD3<Float>) -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.intensity = 1000
        let node = SCNNode()
        node.light = light
        node.position = position
        node.look(at: SCNVector3(CGFloat(target.x), CGFloat(target.y), CGFloat(target.z)))
        return node
    }

    private static func makeAmbientLightNode() -> SCNNode {
        let light = SCNLight()
        light.type = .ambient
        light.intensity = 300
        let node = SCNNode()
        node.light = light
        return node
    }
}
