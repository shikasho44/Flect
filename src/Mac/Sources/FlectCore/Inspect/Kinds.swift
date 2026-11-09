import Foundation
import FlectKit

public enum Kinds {
    private static let text: Set<String> = [
        "TXT", "TEXT", "JSON", "XML", "CSV", "TSV", "HTML", "MD", "INI", "CFG", "CONF",
        "CSS", "JS", "MJS", "CJS", "TS", "TSX", "JSX", "YAML", "YML", "TOML", "LOG",
        "CS", "JAVA", "KT", "PY", "RB", "GO", "RS", "PHP", "PL", "LUA", "SH", "BASH",
        "BAT", "CMD", "PS1", "PSM1", "SQL", "SRT", "VTT", "C", "H", "CPP", "HPP",
        "CC", "HH", "VB", "SWIFT", "R", "TEX", "RST", "ENV", "PROPS", "PROPERTIES",
        "GRADLE", "CMAKE",
    ]

    private static let executable: Set<String> = [
        "PE", "EXE", "SCR", "COM", "PIF", "BAT", "CMD", "JS", "JSE", "VBS", "VBE",
        "WSF", "WSH", "MSI", "MSP", "LNK", "PS1", "PSM1", "PSD1", "CPL", "HTA",
        "MSC", "DLL", "SYS", "GADGET", "APPLICATION",
    ]

    public static func display(_ extension: String) -> String {
        if `extension`.isEmpty { return "" }
        switch `extension`.lowercased() {
        case "jpg", "jpeg": return "JPEG"
        case "tif", "tiff": return "TIFF"
        case "heif", "heic": return "HEIC"
        case "htm", "html": return "HTML"
        case "yml", "yaml": return "YAML"
        case "text", "txt": return "TXT"
        case "aif", "aiff": return "AIFF"
        case "tar.gz", "tgz": return "TAR.GZ"
        // The signature reads a bare .gz as GZIP; without this every one is flagged as mismatched.
        case "gz": return "GZIP"
        case "markdown": return "MD"
        default: return `extension`.uppercased()
        }
    }

    public static func same(_ claimed: String, _ detected: String) -> Bool {
        if claimed.isEmpty { return true }
        if detected.isEmpty { return false }
        if claimed.caseInsensitiveCompare(detected) == .orderedSame { return true }
        if text.contains(claimed.uppercased()), text.contains(detected.uppercased()) { return true }
        if executable.contains(claimed.uppercased()), executable.contains(detected.uppercased()) { return true }
        return false
    }

    public static func isExecutable(_ extension: String) -> Bool { executable.contains(`extension`.uppercased()) }

    public static func isTextExtension(_ extension: String) -> Bool {
        !`extension`.isEmpty && text.contains(display(`extension`).uppercased())
    }

    public static func isTextKind(_ kind: String) -> Bool { text.contains(kind.uppercased()) }

    public static func yesNo(_ value: Bool) -> String {
        Loc.t(value ? "dialog.fileAnalyze.yes" : "dialog.fileAnalyze.no")
    }
}
