import Foundation

public struct MenuEntry: Hashable {
    public let id: String
    public let labelKey: String
    public let label: String
    public let children: [MenuEntry]

    static func leaf(_ id: String, _ label: String, _ labelKey: String? = nil) -> MenuEntry {
        MenuEntry(id: id, labelKey: labelKey ?? "menu." + id, label: label, children: [])
    }

    static func group(_ id: String, _ label: String, _ children: MenuEntry...) -> MenuEntry {
        MenuEntry(id: id, labelKey: "menu." + id, label: label, children: children)
    }

    public var displayName: String {
        labelKey == "menu.to" ? label : Loc.t(labelKey)
    }
}

public enum MenuCatalog {
    public static let categories: [MenuEntry] = [
        .group("folder", "Folder",
               .leaf("folder.removeDuplicate", "Remove Duplicate"),
               .leaf("folder.removeEmpty", "Remove Empty"),
               .leaf("folder.tree", "Tree"),
               .leaf("folder.rename", "Rename"),
               .leaf("folder.analyze", "Analyze"),
               .leaf("folder.compress", "Compress")),

        .group("archive", "Archive",
               .leaf("archive.extract", "Extract")),

        .group("pdf", "PDF",
               .leaf("pdf.preview", "Preview"),
               .leaf("pdf.merge", "Merge"),
               .leaf("pdf.convert.PNG", "to PNG", "menu.to"),
               .leaf("pdf.convert.JPG", "to JPG", "menu.to"),
               .leaf("pdf.convert.TXT", "to TXT", "menu.to")),

        .group("image", "Image",
               .group("image.resize", "Resize",
                      .leaf("image.resize.p1", "Preset 1", "menu.preset1"),
                      .leaf("image.resize.p2", "Preset 2", "menu.preset2"),
                      .leaf("image.resize.custom", "Custom...", "menu.custom")),
               .group("image.compress", "Compress",
                      .leaf("image.compress.p1", "Preset 1", "menu.preset1"),
                      .leaf("image.compress.p2", "Preset 2", "menu.preset2"),
                      .leaf("image.compress.p3", "Preset 3", "menu.preset3"),
                      .leaf("image.compress.p4", "Preset 4", "menu.preset4"),
                      .leaf("image.compress.custom", "Custom...", "menu.custom")),
               .group("image.rotate", "Rotate",
                      .leaf("image.rotate.p1", "Preset 1", "menu.preset1"),
                      .leaf("image.rotate.p2", "Preset 2", "menu.preset2"),
                      .leaf("image.rotate.p3", "Preset 3", "menu.preset3")),
               .group("image.convert", "Convert",
                      .leaf("image.convert.PNG", "to PNG", "menu.to"),
                      .leaf("image.convert.JPG", "to JPG", "menu.to"),
                      .leaf("image.convert.WEBP", "to WEBP", "menu.to"),
                      .leaf("image.convert.HEIC", "to HEIC", "menu.to"),
                      .leaf("image.convert.ICO", "to ICO", "menu.to"),
                      .leaf("image.convert.GIF", "to GIF", "menu.to"),
                      .leaf("image.convert.SVG", "to SVG", "menu.to")),
               .leaf("image.ocr", "OCR"),
               .leaf("image.strip", "Remove Metadata"),
               .leaf("image.chromakey", "Remove Background")),

        .group("video", "Video",
               .group("video.resize", "Resize",
                      .leaf("video.resize.p1", "Preset 1", "menu.preset1"),
                      .leaf("video.resize.p2", "Preset 2", "menu.preset2"),
                      .leaf("video.resize.custom", "Custom", "menu.custom")),
               .leaf("video.trim", "Trim"),
               .leaf("video.thumbnail", "Thumbnail"),
               .leaf("video.subtitles", "Subtitles"),
               .group("video.compress", "Compress",
                      .leaf("video.compress.discord", "Discord"),
                      .leaf("video.compress.p1", "Preset 1", "menu.preset1"),
                      .leaf("video.compress.p2", "Preset 2", "menu.preset2"),
                      .leaf("video.compress.p3", "Preset 3", "menu.preset3"),
                      .leaf("video.compress.custom", "Custom", "menu.custom")),
               .group("video.rotate", "Rotate",
                      .leaf("video.rotate.p1", "Preset 1", "menu.preset1"),
                      .leaf("video.rotate.p2", "Preset 2", "menu.preset2"),
                      .leaf("video.rotate.p3", "Preset 3", "menu.preset3")),
               .group("video.convert", "Convert",
                      .leaf("video.convert.MP4", "to MP4", "menu.to"),
                      .leaf("video.convert.MOV", "to MOV", "menu.to"),
                      .leaf("video.convert.MKV", "to MKV", "menu.to"),
                      .leaf("video.convert.M4A", "to M4A", "menu.to"),
                      .leaf("video.convert.AVI", "to AVI", "menu.to"),
                      .leaf("video.convert.WEBM", "to WEBM", "menu.to"),
                      .leaf("video.convert.FLV", "to FLV", "menu.to"),
                      .leaf("video.convert.GIF", "to GIF", "menu.to")),
               .group("video.extractAudio", "Extract Audio",
                      .leaf("video.extractAudio.MP3", "to MP3", "menu.to"),
                      .leaf("video.extractAudio.M4A", "to M4A", "menu.to"),
                      .leaf("video.extractAudio.WAV", "to WAV", "menu.to"),
                      .leaf("video.extractAudio.AIF", "to AIF", "menu.to"),
                      .leaf("video.extractAudio.AIFF", "to AIFF", "menu.to"),
                      .leaf("video.extractAudio.AAC", "to AAC", "menu.to"),
                      .leaf("video.extractAudio.OGG", "to OGG", "menu.to"),
                      .leaf("video.extractAudio.WMA", "to WMA", "menu.to"))),

        .group("audio", "Audio",
               .group("audio.convert", "Convert",
                      .leaf("audio.convert.MP3", "to MP3", "menu.to"),
                      .leaf("audio.convert.M4A", "to M4A", "menu.to"),
                      .leaf("audio.convert.WAV", "to WAV", "menu.to"),
                      .leaf("audio.convert.AIF", "to AIF", "menu.to"),
                      .leaf("audio.convert.AIFF", "to AIFF", "menu.to"),
                      .leaf("audio.convert.AAC", "to AAC", "menu.to"),
                      .leaf("audio.convert.OGG", "to OGG", "menu.to"),
                      .leaf("audio.convert.WMA", "to WMA", "menu.to")),
               .leaf("audio.subtitles", "Subtitles")),

        .group("text", "Text",
               .group("text.convert", "Convert",
                      .leaf("text.convert.TXT", "to TXT", "menu.to"),
                      .leaf("text.convert.JSON", "to JSON", "menu.to"),
                      .leaf("text.convert.XML", "to XML", "menu.to"),
                      .leaf("text.convert.CSV", "to CSV", "menu.to"),
                      .leaf("text.convert.HTML", "to HTML", "menu.to"),
                      .leaf("text.convert.MD", "to MD", "menu.to")),
               .group("text.encode", "Format",
                      .leaf("text.encode.UTF8", "to UTF-8", "menu.to"),
                      .leaf("text.encode.UTF8BOM", "to UTF-8 (BOM)", "menu.to"),
                      .leaf("text.encode.UTF16", "to UTF-16", "menu.to"),
                      .leaf("text.encode.SJIS", "to Shift_JIS", "menu.to")),
               .group("text.lineEndings", "Line Endings",
                      .leaf("text.lineEndings.CRLF", "to CRLF (Windows)", "menu.to"),
                      .leaf("text.lineEndings.LF", "to LF (Unix)", "menu.to")),
               .leaf("json.pretty", "Pretty Print"),
               .leaf("json.sort", "Sort Keys")),

        .group("jar", "JAR",
               .leaf("jar.decompile", "Decompile")),
    ]

    public static func flatten(_ entries: [MenuEntry]? = nil) -> [MenuEntry] {
        (entries ?? categories).flatMap { [$0] + flatten($0.children) }
    }
}
