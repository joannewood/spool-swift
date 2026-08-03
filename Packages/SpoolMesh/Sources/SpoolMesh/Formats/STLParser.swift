import Foundation

/// Parses both STL variants into a shared, vertex-welded `TriangleMesh` (STL doesn't
/// share vertices between triangles on disk — each triangle repeats its own 3 corner
/// coordinates — so parsing also dedupes exact-match coordinates into shared vertices;
/// without that, the mesh-analysis watertight check would see phantom boundary edges
/// everywhere, the same class of problem the source app's STEP loader had to solve
/// explicitly).
public enum STLParser {
    public enum STLError: Error, Equatable {
        case fileTooShort
        case invalidASCII
    }

    public static func parse(url: URL) throws -> TriangleMesh {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> TriangleMesh {
        // Detect binary vs. ASCII by exact expected-size match, not by trusting a
        // "solid" text prefix — some binary STLs also start with that string in their
        // 80-byte header, since nothing enforces its contents.
        if data.count >= 84 {
            let triCount = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            if 84 + Int(triCount) * 50 == data.count {
                return parseBinary(data: data, triangleCount: triCount)
            }
        }
        return try parseASCII(data: data)
    }

    // MARK: - Binary

    private static func parseBinary(data: Data, triangleCount: UInt32) -> TriangleMesh {
        var welder = VertexWelder()
        var triangles: [(Int32, Int32, Int32)] = []
        triangles.reserveCapacity(Int(triangleCount))

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 84
            for _ in 0..<triangleCount {
                offset += 12 // skip the per-triangle normal
                var indices: [Int32] = []
                indices.reserveCapacity(3)
                for _ in 0..<3 {
                    let x = raw.loadUnaligned(fromByteOffset: offset, as: Float32.self)
                    let y = raw.loadUnaligned(fromByteOffset: offset + 4, as: Float32.self)
                    let z = raw.loadUnaligned(fromByteOffset: offset + 8, as: Float32.self)
                    indices.append(welder.index(for: SIMD3<Float>(x, y, z)))
                    offset += 12
                }
                triangles.append((indices[0], indices[1], indices[2]))
                offset += 2 // attribute byte count, unused
            }
        }
        return TriangleMesh(vertices: welder.vertices, triangles: triangles)
    }

    // MARK: - ASCII

    private static func parseASCII(data: Data) throws -> TriangleMesh {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw STLError.invalidASCII
        }

        var welder = VertexWelder()
        var triangles: [(Int32, Int32, Int32)] = []
        var pending: [Int32] = []
        pending.reserveCapacity(3)

        var iterator = text.split(whereSeparator: { $0.isWhitespace }).makeIterator()
        while let token = iterator.next() {
            guard token == "vertex" else { continue }
            guard let xs = iterator.next(), let ys = iterator.next(), let zs = iterator.next(),
                  let x = Float(xs), let y = Float(ys), let z = Float(zs) else {
                throw STLError.invalidASCII
            }
            pending.append(welder.index(for: SIMD3<Float>(x, y, z)))
            if pending.count == 3 {
                triangles.append((pending[0], pending[1], pending[2]))
                pending.removeAll(keepingCapacity: true)
            }
        }
        guard !triangles.isEmpty else { throw STLError.invalidASCII }
        return TriangleMesh(vertices: welder.vertices, triangles: triangles)
    }
}

/// Exact-match vertex deduplication shared by both STL variants.
struct VertexWelder {
    private(set) var vertices: [SIMD3<Float>] = []
    private var index: [SIMD3<Float>: Int32] = [:]

    mutating func index(for vertex: SIMD3<Float>) -> Int32 {
        if let existing = index[vertex] { return existing }
        let newIndex = Int32(vertices.count)
        vertices.append(vertex)
        index[vertex] = newIndex
        return newIndex
    }
}
