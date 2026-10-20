import Foundation
import FlectKit

final class TextEncode: BatchTask {
    private var target = "UTF8"

    override var title: String { Loc.t("menu.text.encode") }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "UTF8").uppercased()
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let (text, _) = try TextFile.read(path)
        let output = OutputPath.derive(path, suffix: suffix)

        let data: Data
        switch target {
        case "UTF8BOM": data = try TextFile.encode(text, as: .utf8Bom)
        case "UTF16": data = try TextFile.encode(text, as: .utf16)
        case "SJIS":
            let settings = Settings.current.text
            let (encoded, replaced) = try TextFile.encodeShiftJis(text, fallback: settings.sjisFallback,
                                                                   substitute: settings.sjisSubstitute)
            if replaced, settings.sjisFallback == .replaceAndWarn {
                progress.warn(Loc.f("msg.sjisReplaced", fileName(path)))
            }
            data = encoded
        default: data = try TextFile.encode(text, as: .utf8)
        }

        try await OutputPath.producing(output) {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }

    private var suffix: String {
        switch target {
        case "UTF8BOM": return "_utf8bom"
        case "UTF16": return "_utf16"
        case "SJIS": return "_sjis"
        default: return "_utf8"
        }
    }
}

final class TextLineEndings: BatchTask {
    private var target = "CRLF"

    override var title: String { Loc.t("menu.text.lineEndings") }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "CRLF").uppercased()
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let (text, encoding) = try TextFile.read(path)
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let converted = target == "LF" ? normalised : normalised.replacingOccurrences(of: "\n", with: "\r\n")

        let output = OutputPath.derive(path, suffix: target == "LF" ? "_lf" : "_crlf")
        let data = try TextFile.encode(converted, with: encoding)
        try await OutputPath.producing(output) {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }
}

final class TextConvert: BatchTask {
    private var target = "JSON"

    override var title: String { Loc.t("menu.text.convert") }

    override func configure(_ ui: Interaction) async -> Bool {
        target = (request["to"] ?? "JSON").uppercased()
        return true
    }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let (text, _) = try TextFile.read(path)
        let source = (path as NSString).pathExtension.uppercased()
        let converted = target == "TXT"
            ? text
            : try DataFormats.render(try DataFormats.parse(source, text, progress: progress, path: path), as: target)

        let output = OutputPath.derive(path, extension: "." + target.lowercased())
        let data = target == "CSV" ? Data([0xEF, 0xBB, 0xBF]) + Data(converted.utf8) : Data(converted.utf8)
        try await OutputPath.producing(output) {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }
}

final class JsonFormat: BatchTask {
    private let sortKeys: Bool

    init(_ request: Request, sortKeys: Bool) {
        self.sortKeys = sortKeys
        super.init(request)
    }

    override var title: String { Loc.t(sortKeys ? "menu.json.sort" : "menu.json.pretty") }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let (text, _) = try TextFile.read(path)
        let tree = try JSONParser.parse(text, lenient: true)
        let formatted = sortKeys ? SortJson.sort(tree, settings: Settings.current.text.jsonSort) : tree

        let output = OutputPath.derive(path, suffix: sortKeys ? "_sorted" : "_pretty")
        try await OutputPath.producing(output) {
            try Data(JSONWriter.write(formatted).utf8).write(to: URL(fileURLWithPath: output))
        }
    }
}
