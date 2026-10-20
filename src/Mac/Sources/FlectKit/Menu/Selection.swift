import Foundation
import UniformTypeIdentifiers

public enum Category: String {
    case none, folder, pdf, image, video, audio, text, jar, archive
}

public struct SelectionInfo {
    public var paths: [String] = []
    public var category = Category.none
    public var formats: Set<String> = []
    public var maxSize: UInt64 = 0
    public var allJson = false
    public var hasAnimatedGif = false

    public var isEmpty: Bool { paths.isEmpty || category == .none }

    public init() {}
}

public enum Selection {
    private static let maxSelection = 20000
    private static let maxGifProbes = 64

    public static let imageFormats = ["PNG", "JPG", "WEBP", "HEIC", "ICO", "GIF", "SVG"]
    public static let videoFormats = ["MP4", "MOV", "MKV", "M4A", "AVI", "WEBM", "FLV"]
    public static let audioFormats = ["MP3", "M4A", "WAV", "AIF", "AIFF", "AAC", "OGG", "WMA"]

    private static let imageExtensions = [
        "png": "PNG", "jpg": "JPG", "jpeg": "JPG", "webp": "WEBP", "heic": "HEIC", "heif": "HEIC",
        "ico": "ICO", "gif": "GIF", "svg": "SVG",
    ]

    private static let videoExtensions = [
        "mp4": "MP4", "mov": "MOV", "mkv": "MKV", "m4a": "M4A", "avi": "AVI", "webm": "WEBM", "flv": "FLV",
    ]

    private static let audioExtensions = [
        "mp3": "MP3", "wav": "WAV", "aif": "AIF", "aiff": "AIFF", "aac": "AAC", "ogg": "OGG", "wma": "WMA",
    ]

    private static let textFormats = [
        "txt": "TXT", "text": "TXT", "json": "JSON", "csv": "CSV", "xml": "XML", "ini": "INI", "cfg": "CFG",
        "conf": "CFG", "css": "CSS", "html": "HTML", "htm": "HTML", "md": "MD", "markdown": "MD",
    ]

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "log", "csv", "tsv", "ini", "cfg", "conf", "json", "xml", "yaml", "yml",
        "toml", "html", "htm", "css", "js", "mjs", "cjs", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "cc", "hh",
        "cs", "java", "kt", "py", "rb", "go", "rs", "php", "pl", "lua", "sh", "bash", "zsh", "bat", "cmd", "ps1",
        "psm1", "sql", "srt", "vtt", "asc", "tex", "rst", "env", "props", "properties", "gradle", "cmake", "m",
        "mm", "swift", "vb", "r", "jl",
    ]

    public struct Item {
        public var path: String
        public var isDirectory: Bool
        public var size: UInt64?

        public init(path: String, isDirectory: Bool, size: UInt64? = nil) {
            self.path = path
            self.isDirectory = isDirectory
            self.size = size
        }
    }

    public static func item(for url: URL, inspect: Bool) -> Item {
        let path = url.standardizedFileURL.path
        if !inspect {
            var directory = url.hasDirectoryPath
            if !directory, url.pathExtension.isEmpty {
                directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            }
            return Item(path: path, isDirectory: directory)
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isPackageKey])
        let directory = (values?.isDirectory ?? url.hasDirectoryPath) && !(values?.isPackage ?? false)
        return Item(path: path, isDirectory: directory, size: values?.fileSize.map { UInt64($0) })
    }

    public static func classify(_ urls: [URL], inspect: Bool) -> SelectionInfo {
        classify(urls.map { item(for: $0, inspect: inspect) }, probeGifs: inspect)
    }

    public static func classify(_ items: [Item], probeGifs: Bool) -> SelectionInfo {
        var info = SelectionInfo()
        if items.isEmpty || items.count > maxSelection { return info }

        var gifPaths: [String] = []
        var sizeKnown = true

        for item in items {
            let (category, format) = classification(item)
            if category == .none { return SelectionInfo() }
            if info.category == .none {
                info.category = category
            } else if info.category != category {
                return SelectionInfo()
            }
            if let format { info.formats.insert(format) }

            if !item.isDirectory {
                if let size = item.size {
                    info.maxSize = max(info.maxSize, size)
                } else {
                    sizeKnown = false
                }
                if format == "GIF", gifPaths.count < maxGifProbes { gifPaths.append(item.path) }
            }
            info.paths.append(item.path)
        }

        if !sizeKnown { info.maxSize = .max }
        info.allJson = info.category == .text && info.formats == ["JSON"]
        if probeGifs {
            info.hasAnimatedGif = gifPaths.contains(where: GifProbe.isAnimated)
        }
        return info
    }

    static func classification(_ item: Item) -> (Category, String?) {
        let name = (item.path as NSString).lastPathComponent
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension

        if item.isDirectory {
            if !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory), type.conforms(to: .package) {
                return (.none, nil)
            }
            return (.folder, nil)
        }
        if ext.isEmpty { return (.none, nil) }

        if ext == "pdf" { return (.pdf, "PDF") }
        if ext == "jar" { return (.jar, "JAR") }

        if lower.count > 7, lower.hasSuffix(".tar.gz") { return (.archive, "TAR.GZ") }
        if ext == "zip" { return (.archive, "ZIP") }
        if ext == "7z" { return (.archive, "7Z") }
        if ext == "tar" { return (.archive, "TAR") }
        if ext == "rar" { return (.archive, "RAR") }

        if let image = imageExtensions[ext] { return (.image, image) }
        if let video = videoExtensions[ext] { return (.video, video) }
        if let audio = audioExtensions[ext] { return (.audio, audio) }
        if textExtensions.contains(ext) { return (.text, textFormats[ext] ?? "TEXT") }
        return (.none, nil)
    }
}

public enum GifProbe {
    public static func isAnimated(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024) else { return false }
        return isAnimated([UInt8](data))
    }

    static func isAnimated(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return false }
        var index = 13 + colorTableBytes(bytes[10])

        var frames = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:
                guard index + 2 < bytes.count else { return false }
                if bytes[index + 1] == 0xFF {
                    let size = Int(bytes[index + 2])
                    let start = index + 3
                    if size >= 8, start + 8 <= bytes.count, bytes[start..<start + 8].elementsEqual("NETSCAPE".utf8) {
                        return true
                    }
                }
                index = skipBlocks(bytes, from: index + 2)
            case 0x2C:
                frames += 1
                if frames >= 2 { return true }
                guard index + 10 <= bytes.count else { return false }
                index += 10 + colorTableBytes(bytes[index + 9]) + 1
                index = skipBlocks(bytes, from: index)
            default:
                return false
            }
        }
        return false
    }

    private static func colorTableBytes(_ packed: UInt8) -> Int {
        packed & 0x80 == 0 ? 0 : 3 * (1 << (Int(packed & 0x07) + 1))
    }

    private static func skipBlocks(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 0 { return index }
            index += length
        }
        return index
    }
}
