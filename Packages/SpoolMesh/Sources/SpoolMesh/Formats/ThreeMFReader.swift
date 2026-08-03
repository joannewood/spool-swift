import Foundation
import simd
import ZIPFoundation

/// Reads a `.3mf` (a zip containing `3D/3dmodel.model` XML plus optional
/// `Metadata/*.config` files) into a `TriangleMesh`, resolving the build-item /
/// component-reference instancing graph. Carries the two safety guards the source
/// app's Python worker had to add after real production incidents: a 5MB 3MF with 166
/// `<component>` references OOM-killed the worker by multiplying out into far more
/// triangle data than the raw XML size implied — these guards reject that shape before
/// it's ever resolved into geometry, rather than after running out of memory.
public enum ThreeMFReader {
    public enum ThreeMFError: Error, Equatable, CustomStringConvertible {
        case missingModelEntry
        case oversizedMesh(uncompressedBytes: Int)
        case tooManyComponentReferences(count: Int)
        case cyclicComponentReference
        case malformedXML

        /// Phrased to match the substrings the UI's `RenderErrorLabel` keys off of
        /// (`"uncompressed"` + `"safety limit"`, `"build references"` + `"safety
        /// limit"`) — this is the raw text that ends up in `files.render_error`.
        public var description: String {
            switch self {
            case .missingModelEntry:
                return "3MF has no 3D/*.model entry to render"
            case .oversizedMesh(let uncompressedBytes):
                return "3MF's inner mesh data is \(uncompressedBytes) bytes uncompressed, over the "
                    + "\(SafetyLimits.maxUncompressedModelBytes)-byte safety limit — skipped without attempting to render"
            case .tooManyComponentReferences(let count):
                return "3MF has \(count) <item>/<component> build references, over the "
                    + "\(SafetyLimits.maxItemComponentTags)-reference safety limit — skipped without attempting to render"
            case .cyclicComponentReference:
                return "3MF's component references form a cycle"
            case .malformedXML:
                return "3MF's model XML could not be parsed"
            }
        }
    }

    /// Mirrors the source app's `mesh_safety.py` constants exactly.
    public enum SafetyLimits {
        public static let maxUncompressedModelBytes = 12_000_000
        public static let maxItemComponentTags = 60
    }

    private static let rootModelEntryPath = "3D/3dmodel.model"

    public static func read(url: URL) throws -> TriangleMesh {
        let archive = try Archive(url: url, accessMode: .read)

        // A real multi-object export can split object definitions across several
        // `3D/Objects/*.model` entries, referenced from the root model's
        // `<component>` tags — both safety guards, and the actual geometry load
        // below, have to account for every one of them, not just the root entry: the
        // documented 166-`<component>`-reference OOM incident this guard exists to
        // prevent could just as easily hide in a secondary object file as the root.
        let modelEntries = archive.filter { $0.path.hasPrefix("3D/") && $0.path.hasSuffix(".model") }
        guard !modelEntries.isEmpty else { throw ThreeMFError.missingModelEntry }

        // Guard 1: summed *uncompressed* size across every entry, from the zip's own
        // central-directory metadata — before decompressing a single byte.
        let totalUncompressedBytes = modelEntries.reduce(0) { $0 + Int($1.uncompressedSize) }
        guard totalUncompressedBytes <= SafetyLimits.maxUncompressedModelBytes else {
            throw ThreeMFError.oversizedMesh(uncompressedBytes: totalUncompressedBytes)
        }

        // Guard 2: summed raw `<item `/`<component ` tag occurrences across every
        // entry, via a cheap text scan — no XML parsing yet, so a pathological file
        // never reaches the real parse below at all.
        var dataByPath: [String: Data] = [:]
        var totalTagCount = 0
        for entry in modelEntries {
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
            dataByPath[entry.path] = data
            totalTagCount += countBuildReferenceTags(in: data)
        }
        guard totalTagCount <= SafetyLimits.maxItemComponentTags else {
            throw ThreeMFError.tooManyComponentReferences(count: totalTagCount)
        }

        // Only now, having confirmed the file is safe, actually parse every entry
        // into one combined object graph — a component reference in the root model
        // can resolve to an object defined in any of the others.
        var allObjects: [Int: ThreeMFObject] = [:]
        var buildItems: [(objectId: Int, transform: simd_float4x4)] = []
        for entry in modelEntries {
            guard let data = dataByPath[entry.path] else { continue }
            let delegate = ThreeMFParserDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse() else { throw ThreeMFError.malformedXML }
            for (id, object) in delegate.objects { allObjects[id] = object }
            buildItems.append(contentsOf: delegate.buildItems)
        }

        var vertices: [SIMD3<Float>] = []
        var triangles: [(Int32, Int32, Int32)] = []
        var visiting: Set<Int> = []
        for item in buildItems {
            try resolve(
                objectId: item.objectId,
                transform: item.transform,
                objects: allObjects,
                into: &vertices,
                triangles: &triangles,
                visiting: &visiting,
                depth: 0
            )
        }
        return TriangleMesh(vertices: vertices, triangles: triangles)
    }

    /// Matches the source app's `_BUILD_REF_RE = re.compile(rb"<(?:item|component)\s")`
    /// exactly: a literal `<item ` or `<component ` (tag name followed by whitespace,
    /// so it never matches on an unrelated tag name that merely starts the same way),
    /// counted as plain text — never as XML parsing, since the whole point is staying
    /// cheap enough to run before ever committing to a real parse.
    private static func countBuildReferenceTags(in data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        return countOccurrences(of: "<item ", in: text) + countOccurrences(of: "<component ", in: text)
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Flattens the build-item/component instancing graph into world-space geometry.
    /// Guards against a reference cycle independently of the flat tag-count guard
    /// above — a two-tag cycle (A references B references A) would otherwise recurse
    /// forever regardless of how few `<component>` tags are actually present.
    private static func resolve(
        objectId: Int,
        transform: simd_float4x4,
        objects: [Int: ThreeMFObject],
        into vertices: inout [SIMD3<Float>],
        triangles: inout [(Int32, Int32, Int32)],
        visiting: inout Set<Int>,
        depth: Int
    ) throws {
        guard depth < 32 else { throw ThreeMFError.cyclicComponentReference }
        guard !visiting.contains(objectId) else { throw ThreeMFError.cyclicComponentReference }
        guard let object = objects[objectId] else { return } // dangling reference — skip, don't fail the whole file

        visiting.insert(objectId)
        defer { visiting.remove(objectId) }

        if !object.vertices.isEmpty {
            let indexOffset = Int32(vertices.count)
            for v in object.vertices {
                let v4 = transform * SIMD4<Float>(v, 1)
                vertices.append(SIMD3(v4.x, v4.y, v4.z))
            }
            for (a, b, c) in object.triangles {
                triangles.append((a + indexOffset, b + indexOffset, c + indexOffset))
            }
        }
        for component in object.components {
            try resolve(
                objectId: component.objectId,
                transform: transform * component.transform,
                objects: objects,
                into: &vertices,
                triangles: &triangles,
                visiting: &visiting,
                depth: depth + 1
            )
        }
    }
}

struct ThreeMFObject {
    var vertices: [SIMD3<Float>] = []
    var triangles: [(Int32, Int32, Int32)] = []
    var components: [(objectId: Int, transform: simd_float4x4)] = []
}

/// SAX parse of one `3D/*.model` entry — only ever reached after
/// `ThreeMFReader.read`'s two pre-flight guards (summed across every entry) have
/// already confirmed the file is safe, so this has no tag-counting/abort concerns of
/// its own; it just builds this one entry's slice of the combined object graph.
final class ThreeMFParserDelegate: NSObject, XMLParserDelegate {
    private(set) var objects: [Int: ThreeMFObject] = [:]
    private(set) var buildItems: [(objectId: Int, transform: simd_float4x4)] = []

    private var currentObjectId: Int?
    private var inVertices = false
    private var inTriangles = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "object":
            guard let idString = attributeDict["id"], let id = Int(idString) else { return }
            currentObjectId = id
            objects[id] = ThreeMFObject()

        case "vertices":
            inVertices = true

        case "triangles":
            inTriangles = true

        case "vertex":
            guard inVertices, let id = currentObjectId,
                  let x = attributeDict["x"].flatMap(Float.init),
                  let y = attributeDict["y"].flatMap(Float.init),
                  let z = attributeDict["z"].flatMap(Float.init) else { return }
            objects[id]?.vertices.append(SIMD3(x, y, z))

        case "triangle":
            guard inTriangles, let id = currentObjectId,
                  let v1 = attributeDict["v1"].flatMap(Int32.init),
                  let v2 = attributeDict["v2"].flatMap(Int32.init),
                  let v3 = attributeDict["v3"].flatMap(Int32.init) else { return }
            objects[id]?.triangles.append((v1, v2, v3))

        case "component":
            guard let id = currentObjectId,
                  let objectId = attributeDict["objectid"].flatMap(Int.init) else { return }
            let transform = ThreeMFTransform.parse(attributeDict["transform"])
            objects[id]?.components.append((objectId, transform))

        case "item":
            guard let objectId = attributeDict["objectid"].flatMap(Int.init) else { return }
            let transform = ThreeMFTransform.parse(attributeDict["transform"])
            buildItems.append((objectId, transform))

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "vertices": inVertices = false
        case "triangles": inTriangles = false
        case "object": currentObjectId = nil
        default: break
        }
    }
}

/// Parses 3MF's 12-number `transform` attribute (row-major 3x4 affine: 3x3 linear part
/// + translation) into a `simd_float4x4` usable with standard column-vector matrix
/// multiplication (`M * v`, and composition via `outer * inner`).
enum ThreeMFTransform {
    static func parse(_ string: String?) -> simd_float4x4 {
        guard let string,
              case let parts = string.split(separator: " ").compactMap({ Float($0) }),
              parts.count == 12 else {
            return matrix_identity_float4x4
        }
        return simd_float4x4(columns: (
            SIMD4(parts[0], parts[1], parts[2], 0),
            SIMD4(parts[3], parts[4], parts[5], 0),
            SIMD4(parts[6], parts[7], parts[8], 0),
            SIMD4(parts[9], parts[10], parts[11], 1)
        ))
    }
}
