import Foundation

public struct SignatureHit: Equatable {
    public let kind: String
    public let family: String
}

// What the first bytes say the file is, whatever its name claims.
public enum Signature {
    public static func of(_ header: [UInt8], fileName: String) -> SignatureHit {
        let lower = fileName.lowercased()
        func ascii(_ from: Int, _ count: Int) -> String {
            guard header.count >= from + count else { return "" }
            return String(decoding: header[from..<from + count], as: UTF8.self)
        }
        func starts(_ bytes: [UInt8]) -> Bool { header.count >= bytes.count && Array(header.prefix(bytes.count)) == bytes }

        if header.count >= 8, starts([0x89, 0x50, 0x4E, 0x47]) { return .init(kind: "PNG", family: "image") }
        if starts([0xFF, 0xD8, 0xFF]) { return .init(kind: "JPEG", family: "image") }
        if header.count >= 6, starts(Array("GIF".utf8)) { return .init(kind: "GIF", family: "image") }
        if header.count >= 12, starts(Array("RIFF".utf8)) {
            switch ascii(8, 4) {
            case "WEBP": return .init(kind: "WEBP", family: "image")
            case "WAVE": return .init(kind: "WAV", family: "audio")
            case "AVI ": return .init(kind: "AVI", family: "video")
            default: break
            }
        }
        if header.count >= 12, starts(Array("FORM".utf8)), ["AIFF", "AIFC"].contains(ascii(8, 4)) {
            return .init(kind: "AIFF", family: "audio")
        }
        if header.count >= 12, ascii(4, 4) == "ftyp" {
            let brand = ascii(8, 4).lowercased()
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "heif", "mif1", "msf1"].contains(brand) {
                return .init(kind: "HEIC", family: "image")
            }
            if brand == "avif" { return .init(kind: "AVIF", family: "image") }
            if brand == "qt  " { return .init(kind: "MOV", family: "video") }
            if ["m4a ", "m4b ", "m4p "].contains(brand) { return .init(kind: "M4A", family: "audio") }
            return .init(kind: "MP4", family: "video")
        }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) {
            let text = String(decoding: header, as: UTF8.self)
            return text.range(of: "webm", options: .caseInsensitive) != nil
                ? .init(kind: "WEBM", family: "video") : .init(kind: "MKV", family: "video")
        }
        if starts(Array("FLV".utf8)) { return .init(kind: "FLV", family: "video") }
        if starts([0x00, 0x00, 0x01, 0x00]) { return .init(kind: "ICO", family: "image") }
        if header.count >= 5, starts(Array("%PDF".utf8)) { return .init(kind: "PDF", family: "pdf") }
        if header.count >= 4, header[0] == 0x50, header[1] == 0x4B, [0x03, 0x05, 0x07].contains(header[2]) {
            return .init(kind: "ZIP", family: "archive")
        }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .init(kind: "7Z", family: "archive") }
        if header.count >= 6, starts(Array("Rar!".utf8)) { return .init(kind: "RAR", family: "archive") }
        if starts([0x1F, 0x8B]) {
            return lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
                ? .init(kind: "TAR.GZ", family: "archive") : .init(kind: "GZIP", family: "archive")
        }
        if header.count >= 262, ascii(257, 5).hasPrefix("ustar") { return .init(kind: "TAR", family: "archive") }
        if starts(Array("ID3".utf8)) { return .init(kind: "MP3", family: "audio") }
        if header.count >= 2, header[0] == 0xFF, header[1] & 0xE0 == 0xE0, lower.hasSuffix(".mp3") {
            return .init(kind: "MP3", family: "audio")
        }
        if header.count >= 2, header[0] == 0xFF, header[1] & 0xF6 == 0xF0, lower.hasSuffix(".aac") {
            return .init(kind: "AAC", family: "audio")
        }
        if starts(Array("OggS".utf8)) { return .init(kind: "OGG", family: "audio") }
        if starts(Array("fLaC".utf8)) { return .init(kind: "FLAC", family: "audio") }
        if header.count >= 16, starts([0x30, 0x26, 0xB2, 0x75]) { return .init(kind: "WMA", family: "audio") }
        if isLink(header) { return .init(kind: "LNK", family: "lnk") }
        if isPe(header) { return .init(kind: "PE", family: "pe") }
        if isSvg(header) { return .init(kind: "SVG", family: "image") }
        if isText(header) { return .init(kind: "TEXT", family: "text") }
        return .init(kind: "", family: "binary")
    }

    static func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        guard offset >= 0, bytes.count >= offset + 4 else { return 0 }
        return Int32(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                     | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
    }

    private static func isPe(_ header: [UInt8]) -> Bool {
        guard header.count >= 0x40, header[0] == UInt8(ascii: "M"), header[1] == UInt8(ascii: "Z") else { return false }
        let offset = Int(int32(header, at: 0x3C))
        if offset < 0 || offset > header.count - 4 { return true }
        return header[offset] == UInt8(ascii: "P") && header[offset + 1] == UInt8(ascii: "E")
            && header[offset + 2] == 0 && header[offset + 3] == 0
    }

    private static func isLink(_ header: [UInt8]) -> Bool {
        guard header.count >= 20, int32(header, at: 0) == 0x4C else { return false }
        let clsid: [UInt8] = [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]
        return Array(header[4..<20]) == clsid
    }

    private static func isSvg(_ header: [UInt8]) -> Bool {
        let text = String(decoding: header.prefix(2048), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \t\r\n"))
        let lower = text.lowercased()
        return lower.hasPrefix("<svg") || (lower.hasPrefix("<?xml") && lower.contains("<svg"))
    }

    private static func isText(_ header: [UInt8]) -> Bool {
        if header.isEmpty { return false }
        if starts(header, [0xFF, 0xFE]) || starts(header, [0xFE, 0xFF]) || starts(header, [0xEF, 0xBB, 0xBF]) { return true }
        let sample = min(header.count, 4096)
        var printable = 0
        for value in header.prefix(sample) {
            if value == 0 { return false }
            if value == 9 || value == 10 || value == 13 || (value >= 32 && value < 127) || value >= 128 { printable += 1 }
        }
        return Double(printable) >= Double(sample) * 0.90
    }

    private static func starts(_ header: [UInt8], _ bytes: [UInt8]) -> Bool {
        header.count >= bytes.count && Array(header.prefix(bytes.count)) == bytes
    }
}
