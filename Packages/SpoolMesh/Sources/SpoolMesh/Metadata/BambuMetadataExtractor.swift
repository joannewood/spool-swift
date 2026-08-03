import Foundation
import ZIPFoundation

/// Fields extracted from a Bambu Studio 3MF project export.
public struct BambuMetadata: Sendable, Equatable {
    public var nozzleDiameterMM: Double?
    public var layerHeightMM: Double?
    public var infillPercent: Double?
    public var printerModel: String?
    /// The filament actually used on the (first) plate — not `project_settings.config`'s
    /// `filament_type` array, which covers every configured AMS slot whether or not a
    /// given print uses it.
    public var material: String?
    public var filamentColor: String?
    public var filamentUsedGrams: Double?
    public var estimatedPrintMinutes: Double?
    /// Bambu Studio's own client build string (`X-BBL-Client-Version`), distinct from
    /// the `slicer` name itself — which is always the literal "Bambu Studio" once
    /// `project_settings.config` is present at all, not something read from the file.
    public var slicerVersion: String?
}

/// Reads `Metadata/project_settings.config` (JSON — process settings) and
/// `Metadata/slice_info.config` (XML — what was actually printed) from a `.3mf`.
/// `project_settings.config` absent means the file just isn't a Bambu project export
/// (e.g. a plain 3MF from another tool) — that's `nil`, not an error.
public enum BambuMetadataExtractor {
    public static func extract(threeMFAt url: URL) throws -> BambuMetadata? {
        let archive = try Archive(url: url, accessMode: .read)
        guard let settingsEntry = archive["Metadata/project_settings.config"] else {
            return nil
        }

        var settingsData = Data()
        _ = try archive.extract(settingsEntry) { settingsData.append($0) }
        let settingsJSON = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any] ?? [:]

        var metadata = BambuMetadata()
        metadata.nozzleDiameterMM = firstNumber(settingsJSON["nozzle_diameter"])
        metadata.layerHeightMM = firstNumber(settingsJSON["layer_height"])
        metadata.infillPercent = firstPercent(settingsJSON["sparse_infill_density"])
        metadata.printerModel = firstString(settingsJSON["printer_model"])

        if let sliceInfoEntry = archive["Metadata/slice_info.config"] {
            var sliceInfoData = Data()
            _ = try archive.extract(sliceInfoEntry) { sliceInfoData.append($0) }
            let delegate = SliceInfoParserDelegate()
            let parser = XMLParser(data: sliceInfoData)
            parser.delegate = delegate
            _ = parser.parse()
            metadata.filamentUsedGrams = delegate.weightGrams
            // Matches the source app's `round(seconds / 60, 1)`.
            metadata.estimatedPrintMinutes = delegate.predictionSeconds.map { ($0 / 60.0 * 10).rounded() / 10 }
            metadata.material = delegate.firstFilamentType
            metadata.filamentColor = delegate.firstFilamentColor
            metadata.slicerVersion = delegate.slicerVersion
        }

        return metadata
    }

    private static func firstNumber(_ value: Any?) -> Double? {
        if let array = value as? [Any] { return array.first.flatMap(numberFrom) }
        return numberFrom(value)
    }

    private static func numberFrom(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// `sparse_infill_density` is stored as a string with a trailing `%`, e.g. `"15%"`.
    private static func firstPercent(_ value: Any?) -> Double? {
        let raw: String?
        if let array = value as? [Any] {
            raw = array.first as? String
        } else {
            raw = value as? String
        }
        guard let raw else { return numberFrom(value) }
        let trimmed = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
        return Double(trimmed)
    }

    private static func firstString(_ value: Any?) -> String? {
        if let array = value as? [Any] { return array.first as? String }
        return value as? String
    }
}

/// SAX-parses `slice_info.config`, keeping only the first `<plate>` — a multi-plate
/// export's later plates aren't "the" print in the single-file-metadata sense this app
/// stores.
private final class SliceInfoParserDelegate: NSObject, XMLParserDelegate {
    private(set) var weightGrams: Double?
    private(set) var predictionSeconds: Double?
    private(set) var firstFilamentType: String?
    private(set) var firstFilamentColor: String?
    private(set) var slicerVersion: String?

    private var plateCount = 0
    private var inFirstPlate = false
    private var inHeader = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "header":
            inHeader = true

        case "header_item":
            guard inHeader, attributeDict["key"] == "X-BBL-Client-Version" else { return }
            slicerVersion = attributeDict["value"]

        case "plate":
            plateCount += 1
            inFirstPlate = (plateCount == 1)

        case "metadata":
            guard inFirstPlate, let key = attributeDict["key"], let value = attributeDict["value"] else { return }
            switch key {
            case "weight": weightGrams = Double(value)
            case "prediction": predictionSeconds = Double(value)
            default: break
            }

        case "filament":
            guard inFirstPlate, firstFilamentType == nil else { return }
            firstFilamentType = attributeDict["type"]
            firstFilamentColor = attributeDict["color"]

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "header" { inHeader = false }
    }
}
