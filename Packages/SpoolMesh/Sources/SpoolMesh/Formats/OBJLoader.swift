import Foundation
import ModelIO

/// Parses Wavefront OBJ via ModelIO's native importer (no reason to hand-roll an OBJ
/// parser when the platform has one) and immediately flattens the result into
/// `TriangleMesh` — no `MDLMesh`/ModelIO type is allowed to leak past this file, so
/// rendering/analysis stay format-agnostic.
public enum OBJLoader {
    public enum OBJError: Error, Equatable {
        case noMeshFound
        case unsupportedTopology
        case unsupportedVertexFormat
        case unsupportedIndexType
    }

    public static func parse(url: URL) throws -> TriangleMesh {
        let asset = MDLAsset(url: url)
        guard let mdlMesh = firstMesh(in: asset) else { throw OBJError.noMeshFound }
        return try triangleMesh(from: mdlMesh)
    }

    private static func firstMesh(in asset: MDLAsset) -> MDLMesh? {
        for i in 0..<asset.count {
            if let mesh = asset.object(at: i) as? MDLMesh {
                return mesh
            }
        }
        return nil
    }

    private static func triangleMesh(from mdlMesh: MDLMesh) throws -> TriangleMesh {
        guard let positionData = mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition),
              positionData.format == .float3 else {
            throw OBJError.unsupportedVertexFormat
        }

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(mdlMesh.vertexCount)
        let vertexStride = positionData.stride
        let base = positionData.dataStart
        for i in 0..<mdlMesh.vertexCount {
            let floats = (base + i * vertexStride).withMemoryRebound(to: Float.self, capacity: 3) { $0 }
            vertices.append(SIMD3<Float>(floats[0], floats[1], floats[2]))
        }

        var triangles: [(Int32, Int32, Int32)] = []
        let submeshes = (mdlMesh.submeshes as? [MDLSubmesh]) ?? []
        for submesh in submeshes {
            guard submesh.geometryType == .triangles else { throw OBJError.unsupportedTopology }
            let map = submesh.indexBuffer.map()
            let indexCount = submesh.indexCount
            switch submesh.indexType {
            case .uint16:
                let ptr = map.bytes.assumingMemoryBound(to: UInt16.self)
                for t in stride(from: 0, to: indexCount, by: 3) {
                    triangles.append((Int32(ptr[t]), Int32(ptr[t + 1]), Int32(ptr[t + 2])))
                }
            case .uint32:
                let ptr = map.bytes.assumingMemoryBound(to: UInt32.self)
                for t in stride(from: 0, to: indexCount, by: 3) {
                    triangles.append((Int32(ptr[t]), Int32(ptr[t + 1]), Int32(ptr[t + 2])))
                }
            default:
                throw OBJError.unsupportedIndexType
            }
        }

        guard !triangles.isEmpty else { throw OBJError.noMeshFound }
        return TriangleMesh(vertices: vertices, triangles: triangles)
    }
}
