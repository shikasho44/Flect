import Foundation

public struct OutputFeature: Hashable {
    public let key: String
    public let categoryKey: String
    public let labelKey: String
    public let taskIds: [String]

    public var label: String { "\(Loc.t(categoryKey)) / \(Loc.t(labelKey))" }
}

// The features that write new files, as in src/App/Main/Config/OutputCatalog.cs.
public enum OutputCatalog {
    public static let features: [OutputFeature] = [
        .init(key: "video.resize", categoryKey: "settings.nav.video", labelKey: "menu.video.resize", taskIds: ["video.resize"]),
        .init(key: "video.compress", categoryKey: "settings.nav.video", labelKey: "menu.video.compress", taskIds: ["video.compress"]),
        .init(key: "video.convert", categoryKey: "settings.nav.video", labelKey: "menu.video.convert", taskIds: ["video.convert"]),
        .init(key: "video.rotate", categoryKey: "settings.nav.video", labelKey: "menu.video.rotate", taskIds: ["video.rotate"]),
        .init(key: "video.trim", categoryKey: "settings.nav.video", labelKey: "menu.video.trim", taskIds: ["video.trim"]),
        .init(key: "video.thumbnail", categoryKey: "settings.nav.video", labelKey: "menu.video.thumbnail", taskIds: ["video.thumbnail"]),
        .init(key: "video.extractAudio", categoryKey: "settings.nav.video", labelKey: "menu.video.extractAudio",
              taskIds: ["video.extractAudio"]),
        .init(key: "subtitles", categoryKey: "settings.nav.video", labelKey: "menu.video.subtitles",
              taskIds: ["video.subtitles", "audio.subtitles"]),

        .init(key: "image.resize", categoryKey: "settings.nav.image", labelKey: "menu.image.resize", taskIds: ["image.resize"]),
        .init(key: "image.compress", categoryKey: "settings.nav.image", labelKey: "menu.image.compress", taskIds: ["image.compress"]),
        .init(key: "image.convert", categoryKey: "settings.nav.image", labelKey: "menu.image.convert", taskIds: ["image.convert"]),
        .init(key: "image.rotate", categoryKey: "settings.nav.image", labelKey: "menu.image.rotate", taskIds: ["image.rotate"]),
        .init(key: "image.ocr", categoryKey: "settings.nav.image", labelKey: "menu.image.ocr", taskIds: ["image.ocr"]),
        .init(key: "image.strip", categoryKey: "settings.nav.image", labelKey: "menu.image.strip", taskIds: ["image.strip"]),
        .init(key: "image.chromakey", categoryKey: "settings.nav.image", labelKey: "menu.image.chromakey", taskIds: ["image.chromakey"]),

        .init(key: "audio.convert", categoryKey: "settings.output.audio", labelKey: "menu.audio.convert", taskIds: ["audio.convert"]),

        .init(key: "text.convert", categoryKey: "settings.nav.text", labelKey: "menu.text.convert", taskIds: ["text.convert"]),
        .init(key: "text.encode", categoryKey: "settings.nav.text", labelKey: "menu.text.encode", taskIds: ["text.encode"]),
        .init(key: "text.lineEndings", categoryKey: "settings.nav.text", labelKey: "menu.text.lineEndings",
              taskIds: ["text.lineEndings"]),
        .init(key: "json.pretty", categoryKey: "settings.nav.text", labelKey: "menu.json.pretty", taskIds: ["json.pretty"]),
        .init(key: "json.sort", categoryKey: "settings.nav.text", labelKey: "menu.json.sort", taskIds: ["json.sort"]),

        .init(key: "pdf.merge", categoryKey: "settings.output.pdf", labelKey: "menu.pdf.merge", taskIds: ["pdf.merge"]),
        .init(key: "pdf.convert", categoryKey: "settings.output.pdf", labelKey: "menu.pdf.convert", taskIds: ["pdf.convert"]),

        .init(key: "archive.extract", categoryKey: "settings.output.archive", labelKey: "menu.archive.extract",
              taskIds: ["archive.extract"]),
        .init(key: "folder.compress", categoryKey: "settings.nav.folder", labelKey: "menu.folder.compress",
              taskIds: ["folder.compress"]),
    ]

    public static func key(for taskId: String?) -> String? {
        guard let taskId, !taskId.isEmpty else { return nil }
        return features.first { $0.taskIds.contains { $0.caseInsensitiveCompare(taskId) == .orderedSame } }?.key
    }
}
