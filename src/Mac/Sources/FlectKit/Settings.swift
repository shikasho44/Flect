import Foundation

public protocol SettingChoice: RawRepresentable, CaseIterable, Codable, Hashable where RawValue == String {
    static var fallback: Self { get }
}

extension SettingChoice {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self),
           let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(text) == .orderedSame }) {
            self = match
        } else if let index = try? container.decode(Int.self), index >= 0, index < Self.allCases.count {
            self = Array(Self.allCases)[index]
        } else {
            self = Self.fallback
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AppTheme: String, SettingChoice {
    case system = "System", light = "Light", dark = "Dark"
    public static let fallback = AppTheme.system
}

public enum AppLanguage: String, SettingChoice {
    case system = "System", english = "English", japanese = "Japanese", chineseSimplified = "ChineseSimplified"
    public static let fallback = AppLanguage.system
}

public enum DuplicateStrictness: String, SettingChoice {
    case sizeOnly = "SizeOnly", headHash = "HeadHash", fullContent = "FullContent"
    public static let fallback = DuplicateStrictness.fullContent
}

public enum DuplicateKeep: String, SettingChoice {
    case ask = "Ask", oldest = "Oldest", newest = "Newest"
    public static let fallback = DuplicateKeep.ask
}

public enum DeleteMethod: String, SettingChoice {
    case recycleBin = "RecycleBin", permanent = "Permanent"
    public static let fallback = DeleteMethod.recycleBin
}

public enum VideoCodecChoice: String, SettingChoice {
    case h264 = "H264", h265 = "H265", vp9 = "Vp9", av1 = "Av1"
    public static let fallback = VideoCodecChoice.h264
}

public enum VideoContainer: String, SettingChoice {
    case auto = "Auto", mp4 = "Mp4", mkv = "Mkv", webM = "WebM"
    public static let fallback = VideoContainer.auto
}

public enum HardwareEncoder: String, SettingChoice {
    case none = "None", videoToolbox = "VideoToolbox", nvenc = "Nvenc", qsv = "Qsv", amf = "Amf"
    public static let fallback = HardwareEncoder.none
}

public enum EncodePriority: String, SettingChoice {
    case speed = "Speed", balanced = "Balanced", quality = "Quality"
    public static let fallback = EncodePriority.balanced
}

public enum GifDither: String, SettingChoice {
    case none = "None", bayer = "Bayer", floydSteinberg = "FloydSteinberg"
    public static let fallback = GifDither.bayer
}

public enum TrimAccuracy: String, SettingChoice {
    case keyframe = "Keyframe", exact = "Exact"
    public static let fallback = TrimAccuracy.keyframe
}

public enum ThumbnailFormat: String, SettingChoice {
    case png = "Png", jpg = "Jpg"
    public static let fallback = ThumbnailFormat.png
}

public enum SubtitleEngine: String, SettingChoice {
    case apple = "Apple", whisper = "Whisper"
    public static let fallback = SubtitleEngine.apple
}

public enum SubtitleModel: String, SettingChoice {
    case tiny = "Tiny", base = "Base", small = "Small", medium = "Medium", largeV3 = "LargeV3", turbo = "Turbo"
    public static let fallback = SubtitleModel.small
}

public enum SubtitleDevice: String, SettingChoice {
    case auto = "Auto", cpu = "Cpu"
    public static let fallback = SubtitleDevice.auto
}

public enum SubtitleOutput: String, SettingChoice {
    case srt = "Srt", vtt = "Vtt", txt = "Txt"
    public static let fallback = SubtitleOutput.srt
}

public enum ArchiveCompressFormat: String, SettingChoice {
    case zip = "Zip", sevenZip = "SevenZip", tar = "Tar", tarGz = "TarGz"
    public static let fallback = ArchiveCompressFormat.zip
}

public enum BackgroundRemovalMode: String, SettingChoice {
    case aiWithFallback = "AiWithFallback", aiOnly = "AiOnly", chromaKeyOnly = "ChromaKeyOnly"
    public static let fallback = BackgroundRemovalMode.aiWithFallback
}

public enum SjisFallback: String, SettingChoice {
    case replaceAndWarn = "ReplaceAndWarn", substitute = "Substitute", fail = "Fail"
    public static let fallback = SjisFallback.replaceAndWarn
}

public enum JsonKeyOrder: String, SettingChoice {
    case ordinal = "Ordinal", ignoreCase = "IgnoreCase", natural = "Natural"
    public static let fallback = JsonKeyOrder.ordinal
}

public enum OcrOutput: String, SettingChoice {
    case textFile = "TextFile", clipboard = "Clipboard", showOnly = "ShowOnly"
    public static let fallback = OcrOutput.textFile
}

public enum TextEncodingChoice: String, SettingChoice {
    case utf8 = "Utf8", utf8Bom = "Utf8Bom", utf16 = "Utf16", shiftJis = "ShiftJis"
    public static let fallback = TextEncodingChoice.utf8Bom
}

public enum ReportFormat: String, SettingChoice {
    case csv = "Csv", json = "Json", html = "Html", txt = "Txt"
    public static let fallback = ReportFormat.csv
}

public struct ExclusionRules: Codable, Equatable {
    public var folders = ""
    public var files = ""
    public var extensions = ""
    public init() {}
}

public struct GeneralSettings: Codable, Equatable {
    public var theme = AppTheme.system
    public var language = AppLanguage.system
    public var closeOnSuccess = true
    public var closeOnFailure = false
    public var closeOnCancel = true
    public var autoUpdate = true
    public var hiddenMenuItems: [String] = []
    public init() {}
}

public struct DuplicateSettings: Codable, Equatable {
    public var strictness = DuplicateStrictness.fullContent
    public var matchName = false
    public var matchTimestamp = false
    public var ignoreEmptyFiles = true
    public var minimumBytes: Int64 = 0
    public var keep = DuplicateKeep.ask
    public init() {}
}

public struct RenameSettings: Codable, Equatable {
    public var useNumbering = true
    public var digitCount = 0
    public var startNumber = 1
    public var dryRun = false
    public var exclusions = ExclusionRules()
    public init() {}
}

public struct EmptyFolderSettings: Codable, Equatable {
    public var ignoreZeroByteFiles = false
    public var ignoreDesktopIni = true
    public var ignoreThumbsDb = true
    public init() {}
}

public struct TreeSettings: Codable, Equatable {
    public var foldersOnly = false
    public var exclusions = ExclusionRules()
    public init() {}
}

public struct AnalyzeSettings: Codable, Equatable {
    public var saveFormat = ReportFormat.csv
    public var exclusions = ExclusionRules()
    public init() {}
}

public struct ArchiveSettings: Codable, Equatable {
    public var compressFormat = ArchiveCompressFormat.zip
    public init() {}
}

public struct FolderSettings: Codable, Equatable {
    public var duplicates = DuplicateSettings()
    public var deleteMethod = DeleteMethod.recycleBin
    public var scanExclusions = ExclusionRules()
    public var rename = RenameSettings()
    public var empty = EmptyFolderSettings()
    public var tree = TreeSettings()
    public var analyze = AnalyzeSettings()
    public var archive = ArchiveSettings()
    public init() {}
}

public struct VideoPresets: Codable, Equatable {
    public static let discordLimit: Int64 = 20 * 1024 * 1024
    public static let legacyDiscordLimit: Int64 = 10 * 1024 * 1024

    public var resizeA = 50.0
    public var resizeB = 25.0
    public var compressDiscord = VideoPresets.discordLimit
    public var compressA: Int64 = 50 * 1024 * 1024
    public var compressB: Int64 = 25 * 1024 * 1024
    public var compressC: Int64 = 5 * 1024 * 1024
    public var rotateA = 45.0
    public var rotateB = 90.0
    public var rotateC = 180.0
    public init() {}
}

public struct TrimSettings: Codable, Equatable {
    public var accuracy = TrimAccuracy.keyframe
    public init() {}
}

public struct ThumbnailSettings: Codable, Equatable {
    public var format = ThumbnailFormat.png
    public var quality = 90
    public var maxWidth = 0
    public init() {}
}

public struct SubtitlesSettings: Codable, Equatable {
    public var engine = SubtitleEngine.apple
    public var model = SubtitleModel.small
    public var device = SubtitleDevice.auto
    public var language = ""
    public var output = SubtitleOutput.srt
    public init() {}
}

public struct VideoSettings: Codable, Equatable {
    public var presets = VideoPresets()
    public var trim = TrimSettings()
    public var thumbnail = ThumbnailSettings()
    public var codec = VideoCodecChoice.h264
    public var container = VideoContainer.auto
    public var hardware = HardwareEncoder.none
    public var priority = EncodePriority.balanced
    public var gifFps = 15
    public var gifMaxWidth = 640
    public var gifDither = GifDither.bayer
    public var rotateFillColor = "#000000"
    public var subtitles = SubtitlesSettings()
    public init() {}
}

public struct ImagePresets: Codable, Equatable {
    public var resizeA = 50.0
    public var resizeB = 25.0
    public var compressA: Int64 = 10 * 1024 * 1024
    public var compressB: Int64 = 5 * 1024 * 1024
    public var compressC: Int64 = 3 * 1024 * 1024
    public var compressD: Int64 = 1 * 1024 * 1024
    public var rotateA = 45.0
    public var rotateB = 90.0
    public var rotateC = 180.0
    public init() {}
}

public struct MetadataSettings: Codable, Equatable {
    public var removeExif = true
    public var removeGps = true
    public var removeComments = true
    public var removeColorProfile = false
    public var applyOrientation = true
    public init() {}
}

public struct ImageSettings: Codable, Equatable {
    public var presets = ImagePresets()
    public var allowWebpFallback = true
    public var webpQuality = 80
    public var backgroundMode = BackgroundRemovalMode.aiWithFallback
    public var backgroundKeyColor = "#00FF00"
    public var backgroundTolerance = 25.0
    public var metadata = MetadataSettings()
    public init() {}
}

public struct JsonSortSettings: Codable, Equatable {
    public var comparison = JsonKeyOrder.ordinal
    public var descending = false
    public var recursive = true
    public var sortPrimitiveArrays = false
    public var pinnedKeys = ""
    public init() {}
}

public struct TextSettings: Codable, Equatable {
    public var sjisFallback = SjisFallback.replaceAndWarn
    public var sjisSubstitute = "?"
    public var jsonSort = JsonSortSettings()
    public init() {}
}

public struct OcrSettings: Codable, Equatable {
    public var language = ""
    public var output = OcrOutput.textFile
    public var encoding = TextEncodingChoice.utf8Bom
    public var suppressLanguageNotice = false
    public init() {}
}

public struct DecompileSettings: Codable, Equatable {
    public var outputPath = ""
    public init() {}
}

public struct CodeSettings: Codable, Equatable {
    public var decompile = DecompileSettings()
    public init() {}
}

public struct OutputSettings: Codable, Equatable {
    // Feature key (OutputCatalog) to the folder its results go to. Missing or empty means beside the original.
    public var folders: [String: String] = [:]
    public init() {}
}

public struct Settings: Codable, Equatable {
    public static let fileName = "settings.json"
    private static let schemaVersion = 1

    public var version = 0
    public var general = GeneralSettings()
    public var folder = FolderSettings()
    public var video = VideoSettings()
    public var image = ImageSettings()
    public var text = TextSettings()
    public var ocr = OcrSettings()
    public var code = CodeSettings()
    public var output = OutputSettings()

    public init() {}

    private static let lock = NSLock()
    private static var cached: Settings?

    public static var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    public static func reload() -> Settings {
        lock.lock()
        cached = nil
        lock.unlock()
        return current
    }

    public static func load() -> Settings {
        guard var settings = Store.read(Settings.self, from: fileName, defaults: Settings()) else {
            return Settings()
        }
        if settings.version >= schemaVersion { return settings }

        settings.upgrade()
        settings.version = schemaVersion
        Store.write(settings, to: fileName)
        return settings
    }

    private mutating func upgrade() {
        if video.presets.compressDiscord == VideoPresets.legacyDiscordLimit {
            video.presets.compressDiscord = VideoPresets.discordLimit
        }
    }

    public func save() {
        var copy = self
        copy.version = Settings.schemaVersion
        Store.write(copy, to: Settings.fileName)
        Settings.lock.lock()
        Settings.cached = copy
        Settings.lock.unlock()
    }

    public static func reset() {
        Store.delete(fileName)
        lock.lock()
        cached = Settings()
        lock.unlock()
    }
}
