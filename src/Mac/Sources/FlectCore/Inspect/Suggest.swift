import Foundation
import FlectKit

public struct SuggestCommand: Equatable {
    public let label: String
    public let verb: String
}

public struct SuggestLink: Equatable {
    public let label: String
    public let commands: [SuggestCommand]
    // One command that runs straight away instead of opening a list.
    public let direct: Bool
}

// The menu entries a fact points to, such as Compress beside the size: the same choices the Finder menu offers.
public final class Suggest {
    private enum Kind { case none, image, video, audio, text, pdf, archive }

    private static let imageFormats = ["PNG", "JPG", "WEBP", "HEIC", "ICO", "GIF", "SVG"]
    private static let videoFormats = ["MP4", "MOV", "MKV", "M4A", "AVI", "WEBM", "FLV"]
    private static let audioFormats = ["MP3", "M4A", "WAV", "AIF", "AIFF", "AAC", "OGG", "WMA"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "log", "csv", "tsv", "ini", "cfg", "conf", "json", "xml",
        "yaml", "yml", "toml", "html", "htm", "css", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "c", "h", "cpp", "hpp", "cc", "hh", "cs", "java", "kt", "py", "rb", "go", "rs", "php",
        "pl", "lua", "sh", "bash", "bat", "cmd", "ps1", "psm1", "sql", "srt", "vtt", "asc",
        "tex", "rst", "env", "props", "properties", "gradle", "cmake", "m", "mm", "swift", "vb",
        "r", "jl",
    ]

    private let path: String
    private let length: Int64
    private let hidden: Set<String>
    private let image: ImagePresets
    private let video: VideoPresets
    private let kind: Kind
    private let format: String?
    private lazy var animated: Bool = format == "GIF" && GifMotion.isAnimated(path)

    public init(path: String, settings: Settings) {
        self.path = path
        length = FileSystem.size(of: path) ?? 0
        hidden = Set(settings.general.hiddenMenuItems.map { $0.lowercased() })
        image = settings.image.presets
        video = settings.video.presets
        (kind, format) = Suggest.classify(path)
    }

    public static func canCopy(_ key: String?) -> Bool {
        ["dialog.fileAnalyze.path", "dialog.fileAnalyze.linkTarget", "dialog.fileAnalyze.zoneUrl",
         "dialog.fileAnalyze.target"].contains(key ?? "")
    }

    public func link(_ key: String?) -> SuggestLink? {
        switch key {
        case "dialog.fileAnalyze.sizeOnDisk": return compress()
        case "dialog.fileAnalyze.contents": return contents()
        case "dialog.fileAnalyze.duration": return trim()
        case "dialog.fileAnalyze.resolution": return kind == .video ? resize("video") : nil
        case "dialog.fileAnalyze.dimensions": return kind == .image ? resize("image") : nil
        case "dialog.fileAnalyze.encoding":
            return kind == .text ? choices("text.encode", [("text.encode.UTF8", "to UTF-8", "UTF8"),
                                                            ("text.encode.UTF8BOM", "to UTF-8 (BOM)", "UTF8BOM"),
                                                            ("text.encode.UTF16", "to UTF-16", "UTF16"),
                                                            ("text.encode.SJIS", "to Shift_JIS", "SJIS")]) : nil
        case "dialog.fileAnalyze.newlines":
            return kind == .text ? choices("text.lineEndings", [("text.lineEndings.CRLF", "to CRLF (Windows)", "CRLF"),
                                                                 ("text.lineEndings.LF", "to LF (Unix)", "LF")]) : nil
        default: return nil
        }
    }

    private func compress() -> SuggestLink? {
        let mib: Int64 = 1024 * 1024
        var commands: [SuggestCommand] = []
        switch kind {
        case .image:
            let verb = "image.compress?bytes="
            preset(&commands, "image.compress.p1", image.compressA, 10 * mib, verb)
            preset(&commands, "image.compress.p2", image.compressB, 5 * mib, verb)
            preset(&commands, "image.compress.p3", image.compressC, 3 * mib, verb)
            preset(&commands, "image.compress.p4", image.compressD, 1 * mib, verb)
            add(&commands, "image.compress.custom", Loc.t("menu.custom"), verb + "custom")
            return menu("image.compress", "menu.image.compress", commands)
        case .video:
            let discord = video.compressDiscord > 0 ? video.compressDiscord : VideoPresets.discordLimit
            if length > discord {
                add(&commands, "video.compress.discord",
                    "\(Loc.t("menu.video.compress.discord")) (\(Formatting.shortBytes(discord)))", "video.compress?preset=discord")
            }
            let verb = "video.compress?bytes="
            preset(&commands, "video.compress.p1", video.compressA, 50 * mib, verb)
            preset(&commands, "video.compress.p2", video.compressB, 25 * mib, verb)
            preset(&commands, "video.compress.p3", video.compressC, 5 * mib, verb)
            add(&commands, "video.compress.custom", Loc.t("menu.custom"), verb + "custom")
            return menu("video.compress", "menu.video.compress", commands)
        default:
            return nil
        }
    }

    private func preset(_ commands: inout [SuggestCommand], _ id: String, _ configured: Int64, _ fallback: Int64, _ verb: String) {
        let bytes = configured > 0 ? configured : fallback
        if length <= bytes { return }
        add(&commands, id, Formatting.shortBytes(bytes), verb + String(bytes))
    }

    private func resize(_ domain: String) -> SuggestLink? {
        let (a, b) = domain == "image" ? (image.resizeA, image.resizeB) : (video.resizeA, video.resizeB)
        let first = Formatting.number(a > 0 && a.isFinite ? a : 50)
        let second = Formatting.number(b > 0 && b.isFinite ? b : 25)
        let verb = domain + ".resize?scale="
        var commands: [SuggestCommand] = []
        add(&commands, domain + ".resize.p1", first + "%", verb + first)
        add(&commands, domain + ".resize.p2", second + "%", verb + second)
        add(&commands, domain + ".resize.custom", Loc.t("menu.custom"), verb + "custom")
        return menu(domain + ".resize", "menu.\(domain).resize", commands)
    }

    private func contents() -> SuggestLink? {
        switch kind {
        case .image: return animated ? nil : convert("image", Suggest.imageFormats, appendGif: false)
        case .video: return convert("video", Suggest.videoFormats, appendGif: true)
        case .audio: return convert("audio", Suggest.audioFormats, appendGif: false)
        case .text: return textConvert()
        case .pdf: return convert("pdf", ["PNG", "JPG", "TXT"], appendGif: false, skipCurrent: false)
        case .archive: return leaf("archive.extract", "menu.archive.extract")
        case .none: return nil
        }
    }

    private func convert(_ domain: String, _ formats: [String], appendGif: Bool, skipCurrent: Bool = true) -> SuggestLink? {
        var commands: [SuggestCommand] = []
        for target in formats where !(skipCurrent && target.caseInsensitiveCompare(format ?? "") == .orderedSame) {
            add(&commands, "\(domain).convert.\(target)", "to " + target, "\(domain).convert?to=\(target)")
        }
        if appendGif { add(&commands, "\(domain).convert.GIF", "to GIF", "\(domain).convert?to=GIF") }
        return menu(domain + ".convert", "menu.\(domain).convert", commands)
    }

    private func textConvert() -> SuggestLink? {
        guard let format else { return nil }
        var commands: [SuggestCommand] = []
        for target in MenuBuilder.textTargets(from: format.uppercased()) {
            add(&commands, "text.convert." + target, "to " + target, "text.convert?to=" + target)
        }
        return menu("text.convert", "menu.text.convert", commands)
    }

    private func trim() -> SuggestLink? {
        switch kind {
        case .video: return leaf("video.trim", "menu.video.trim")
        case .audio: return leaf("audio.trim", "menu.audio.trim")
        default: return nil
        }
    }

    private func choices(_ id: String, _ items: [(String, String, String)]) -> SuggestLink? {
        var commands: [SuggestCommand] = []
        for (child, label, to) in items { add(&commands, child, label, "\(id)?to=\(to)") }
        return menu(id, "menu." + id, commands)
    }

    private func leaf(_ id: String, _ labelKey: String) -> SuggestLink? {
        if isHidden(id) { return nil }
        let label = Loc.t(labelKey)
        return SuggestLink(label: label, commands: [SuggestCommand(label: label, verb: id)], direct: true)
    }

    private func menu(_ id: String, _ labelKey: String, _ commands: [SuggestCommand]) -> SuggestLink? {
        if isHidden(id) || commands.isEmpty { return nil }
        return SuggestLink(label: Loc.t(labelKey), commands: commands, direct: false)
    }

    private func add(_ commands: inout [SuggestCommand], _ id: String, _ label: String, _ verb: String) {
        if !isHidden(id) { commands.append(SuggestCommand(label: label, verb: verb)) }
    }

    private func isHidden(_ id: String) -> Bool { hidden.contains(id.lowercased()) }

    private static func classify(_ path: String) -> (Kind, String?) {
        let name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return (.archive, "TAR.GZ") }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "": return (.none, nil)
        case "pdf": return (.pdf, "PDF")
        case "zip": return (.archive, "ZIP")
        case "7z": return (.archive, "7Z")
        case "tar": return (.archive, "TAR")
        case "rar": return (.archive, "RAR")
        case "png": return (.image, "PNG")
        case "jpg", "jpeg": return (.image, "JPG")
        case "webp": return (.image, "WEBP")
        case "heic", "heif": return (.image, "HEIC")
        case "ico": return (.image, "ICO")
        case "gif": return (.image, "GIF")
        case "svg": return (.image, "SVG")
        case "mp4": return (.video, "MP4")
        case "mov": return (.video, "MOV")
        case "mkv": return (.video, "MKV")
        case "m4a": return (.video, "M4A")
        case "avi": return (.video, "AVI")
        case "webm": return (.video, "WEBM")
        case "flv": return (.video, "FLV")
        case "mp3": return (.audio, "MP3")
        case "wav": return (.audio, "WAV")
        case "aif": return (.audio, "AIF")
        case "aiff": return (.audio, "AIFF")
        case "aac": return (.audio, "AAC")
        case "ogg": return (.audio, "OGG")
        case "wma": return (.audio, "WMA")
        default:
            guard textExtensions.contains(ext) else { return (.none, nil) }
            switch ext {
            case "txt", "text": return (.text, "TXT")
            case "json": return (.text, "JSON")
            case "csv": return (.text, "CSV")
            case "xml": return (.text, "XML")
            case "ini": return (.text, "INI")
            case "cfg", "conf": return (.text, "CFG")
            case "css": return (.text, "CSS")
            case "html", "htm": return (.text, "HTML")
            case "md", "markdown": return (.text, "MD")
            default: return (.text, "TEXT")
            }
        }
    }
}

final class FileAnalyze: FlectTask {
    private var report: FileReport?

    override var title: String { Loc.t("menu.file.analyze") }

    override func run(_ progress: TaskProgress) async throws {
        guard request.paths.count == 1 else { throw FlectError(Loc.t("dialog.fileAnalyze.single")) }
        progress.indeterminate()
        progress.status(fileName(request.paths[0]))
        report = try await Examine.inspect(request.paths[0])
    }

    override func present(_ ui: Interaction) async {
        if let report { await ui.showFileAnalysis(report) }
    }
}
