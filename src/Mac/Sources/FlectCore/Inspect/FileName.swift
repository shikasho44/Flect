import Foundation
import FlectKit

public struct NameInfo {
    public let `extension`: String
    public let claimedKind: String
    public let shownName: String?
    public let markedName: String?
    public let disguiseAs: String?
    public let alerts: [String]
}

// Tricks in a name: an executable behind a second extension, right-to-left overrides, invisible and look-alike letters.
public enum FileName {
    private static let decoys: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "heif", "ico", "gif", "svg", "bmp", "tif", "tiff",
        "mp4", "mov", "mkv", "m4a", "avi", "webm", "flv", "wmv",
        "mp3", "wav", "aif", "aiff", "aac", "ogg", "wma", "flac",
        "pdf", "zip", "7z", "tar", "rar", "gz", "tgz",
        "txt", "text", "json", "csv", "tsv", "xml", "html", "htm", "md", "markdown",
        "ini", "cfg", "conf", "log", "yaml", "yml", "toml", "css",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "odt", "ods", "odp",
        "srt", "vtt", "cs", "java", "py", "c", "cpp", "h", "rs", "go",
    ]

    private static let confusable: [UInt32: (looks: String, name: String)] = [
        0x0430: ("a", "Cyrillic a"), 0x0435: ("e", "Cyrillic ie"), 0x043E: ("o", "Cyrillic o"),
        0x0440: ("p", "Cyrillic er"), 0x0441: ("c", "Cyrillic es"), 0x0443: ("y", "Cyrillic u"),
        0x0445: ("x", "Cyrillic ha"), 0x0455: ("s", "Cyrillic dze"), 0x0456: ("i", "Cyrillic i"),
        0x0458: ("j", "Cyrillic je"), 0x04BB: ("h", "Cyrillic shha"), 0x0501: ("d", "Cyrillic komi de"),
        0x051B: ("q", "Cyrillic qa"), 0x051D: ("w", "Cyrillic we"),
        0x0391: ("A", "Greek Alpha"), 0x0392: ("B", "Greek Beta"), 0x0395: ("E", "Greek Epsilon"),
        0x0396: ("Z", "Greek Zeta"), 0x0397: ("H", "Greek Eta"), 0x0399: ("I", "Greek Iota"),
        0x039A: ("K", "Greek Kappa"), 0x039C: ("M", "Greek Mu"), 0x039D: ("N", "Greek Nu"),
        0x039F: ("O", "Greek Omicron"), 0x03A1: ("P", "Greek Rho"), 0x03A4: ("T", "Greek Tau"),
        0x03A5: ("Y", "Greek Upsilon"), 0x03A7: ("X", "Greek Chi"), 0x03B1: ("a", "Greek alpha"),
        0x03BF: ("o", "Greek omicron"), 0x03C1: ("p", "Greek rho"),
    ]

    public static func read(_ fileName: String) -> NameInfo {
        let ext = extensionOf(fileName)
        let claimed = Kinds.display(ext)
        var alerts: [String] = []
        var marked: String?
        var shown: String?

        var bidi: [String] = []
        var hidden: [String] = []
        var markedName = ""
        for scalar in fileName.unicodeScalars {
            if let name = bidiName(scalar) {
                bidi.append(label(name, scalar))
                markedName += "[\(name)]"
            } else if let name = hiddenName(scalar) {
                hidden.append(label(name, scalar))
                markedName += "[\(name)]"
            } else {
                markedName.unicodeScalars.append(scalar)
            }
        }

        if !bidi.isEmpty || !hidden.isEmpty {
            marked = markedName
            let visual = visual(fileName)
            if visual != fileName { shown = visual }
        }
        if !bidi.isEmpty { alerts.append(Loc.f("dialog.fileAnalyze.bidi", distinct(bidi).joined(separator: ", "))) }
        if !hidden.isEmpty { alerts.append(Loc.f("dialog.fileAnalyze.zeroWidth", distinct(hidden).joined(separator: ", "))) }
        let lookalikes = lookalikes(fileName)
        if !lookalikes.isEmpty { alerts.append(Loc.f("dialog.fileAnalyze.homoglyph", lookalikes.joined(separator: ", "))) }

        return NameInfo(extension: ext, claimedKind: claimed, shownName: shown, markedName: marked,
                        disguiseAs: disguise(fileName, ext, shown), alerts: alerts)
    }

    static func extensionOf(_ fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(fileName.suffix(6)) }
        if lower.hasSuffix(".tgz") { return String(fileName.suffix(3)) }
        guard let dot = fileName.lastIndex(of: "."), fileName.index(after: dot) != fileName.endIndex else { return "" }
        return String(fileName[fileName.index(after: dot)...])
    }

    private static func disguise(_ fileName: String, _ ext: String, _ shown: String?) -> String? {
        guard Kinds.isExecutable(ext) else { return nil }
        if let shown, !shown.isEmpty {
            let shownExtension = extensionOf(shown)
            if !shownExtension.isEmpty, !Kinds.isExecutable(shownExtension),
               shownExtension.caseInsensitiveCompare(ext) != .orderedSame {
                return Kinds.display(shownExtension)
            }
        }
        var stem = fileName
        if stem.lowercased().hasSuffix("." + ext.lowercased()) { stem = String(stem.dropLast(ext.count + 1)) }
        var decoy: String?
        for part in stem.split(separator: ".", omittingEmptySubsequences: false) where decoys.contains(part.lowercased()) {
            decoy = Kinds.display(String(part))
        }
        return decoy
    }

    // How Finder draws a name with a right-to-left override: the overridden run reversed, controls dropped.
    private static func visual(_ fileName: String) -> String {
        let scalars = Array(fileName.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x202E {
                var end = index + 1
                while end < scalars.count, scalars[end].value != 0x202C { end += 1 }
                var reverse = end - 1
                while reverse > index {
                    if bidiName(scalars[reverse]) == nil, hiddenName(scalars[reverse]) == nil { result.append(scalars[reverse]) }
                    reverse -= 1
                }
                index = end + 1
                continue
            }
            if bidiName(scalar) == nil, hiddenName(scalar) == nil { result.append(scalar) }
            index += 1
        }
        return String(result)
    }

    private static func lookalikes(_ fileName: String) -> [String] {
        var found: [String] = []
        var seen = Set<UInt32>()
        for token in fileName.split(separator: ".", omittingEmptySubsequences: false) {
            let ascii = token.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
            for scalar in token.unicodeScalars {
                let value = scalar.value
                guard seen.insert(value).inserted else { continue }
                if value >= 0x1D400 && value <= 0x1D7FF {
                    found.append("U+\(String(value, radix: 16, uppercase: true)) (mathematical alphanumeric)")
                    continue
                }
                guard value <= 0xFFFF else { continue }
                if let confusable = confusable[value] {
                    if !ascii { continue }
                    found.append("\(Character(scalar)) (U+\(hex4(value)), \(confusable.looks), \(confusable.name))")
                    continue
                }
                if value >= 0xFF21 && value <= 0xFF3A {
                    found.append(fullWidth(scalar, Character(UnicodeScalar(65 + value - 0xFF21)!)))
                } else if value >= 0xFF41 && value <= 0xFF5A {
                    found.append(fullWidth(scalar, Character(UnicodeScalar(97 + value - 0xFF41)!)))
                } else if value >= 0xFF10 && value <= 0xFF19 {
                    found.append(fullWidth(scalar, Character(UnicodeScalar(48 + value - 0xFF10)!)))
                }
            }
        }
        return found
    }

    private static func fullWidth(_ scalar: Unicode.Scalar, _ looks: Character) -> String {
        "\(Character(scalar)) (U+\(hex4(scalar.value)), \(looks), fullwidth)"
    }

    private static func label(_ name: String, _ scalar: Unicode.Scalar) -> String { "\(name) (U+\(hex4(scalar.value)))" }

    private static func hex4(_ value: UInt32) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - text.count)) + text
    }

    private static func distinct(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private static func bidiName(_ scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x202A: return "LRE"
        case 0x202B: return "RLE"
        case 0x202C: return "PDF"
        case 0x202D: return "LRO"
        case 0x202E: return "RLO"
        case 0x2066: return "LRI"
        case 0x2067: return "RLI"
        case 0x2068: return "FSI"
        case 0x2069: return "PDI"
        default: return nil
        }
    }

    private static func hiddenName(_ scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x200B: return "ZWSP"
        case 0x200C: return "ZWNJ"
        case 0x200D: return "ZWJ"
        case 0x2060: return "WJ"
        case 0xFEFF: return "BOM"
        case 0x00AD: return "SHY"
        default: return nil
        }
    }
}
