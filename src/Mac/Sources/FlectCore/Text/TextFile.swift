import Foundation
import FlectKit

public struct TextEncodingInfo: Equatable {
    public var encoding: String.Encoding
    public var byteOrderMark: Bool
}

public enum TextFile {
    public static let shiftJis = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    public static func read(_ path: String) throws -> (String, TextEncodingInfo) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> (String, TextEncodingInfo) {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), TextEncodingInfo(encoding: .utf8, byteOrderMark: true))
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            let encoding: String.Encoding = bytes[0] == 0xFF ? .utf32LittleEndian : .utf32BigEndian
            if let text = String(data: data.dropFirst(4), encoding: encoding) {
                return (text, TextEncodingInfo(encoding: encoding, byteOrderMark: true))
            }
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let encoding: String.Encoding = bytes[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            if let text = String(data: data.dropFirst(2), encoding: encoding) {
                return (text, TextEncodingInfo(encoding: encoding, byteOrderMark: true))
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, TextEncodingInfo(encoding: .utf8, byteOrderMark: false))
        }

        var converted: NSString?
        var lossy: ObjCBool = false
        let suggestions: [String.Encoding] = [
            shiftJis, .japaneseEUC, .iso2022JP,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
            .windowsCP1252,
        ]
        let detected = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: suggestions.map { NSNumber(value: $0.rawValue) },
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)

        if detected != 0, let converted {
            return (converted as String, TextEncodingInfo(encoding: String.Encoding(rawValue: detected), byteOrderMark: false))
        }
        return (String(decoding: data, as: UTF8.self), TextEncodingInfo(encoding: .utf8, byteOrderMark: false))
    }

    public static func encode(_ text: String, as choice: TextEncodingChoice) throws -> Data {
        switch choice {
        case .utf8: return Data(text.utf8)
        case .utf8Bom: return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16: return try encode(text, with: TextEncodingInfo(encoding: .utf16LittleEndian, byteOrderMark: true))
        case .shiftJis: return try encodeShiftJis(text, fallback: .replaceAndWarn, substitute: "?").0
        }
    }

    public static func encode(_ text: String, with info: TextEncodingInfo) throws -> Data {
        var prefix = Data()
        if info.byteOrderMark {
            switch info.encoding {
            case .utf8: prefix = Data([0xEF, 0xBB, 0xBF])
            case .utf16LittleEndian: prefix = Data([0xFF, 0xFE])
            case .utf16BigEndian: prefix = Data([0xFE, 0xFF])
            case .utf32LittleEndian: prefix = Data([0xFF, 0xFE, 0x00, 0x00])
            case .utf32BigEndian: prefix = Data([0x00, 0x00, 0xFE, 0xFF])
            default: break
            }
        }
        guard let body = text.data(using: info.encoding, allowLossyConversion: true) else {
            throw FlectError("This text could not be encoded.")
        }
        return prefix + body
    }

    public static func encodeShiftJis(_ text: String, fallback: SjisFallback, substitute: String) throws -> (Data, Bool) {
        if let strict = text.data(using: shiftJis, allowLossyConversion: false) { return (strict, false) }
        if fallback == .fail { throw FlectError(Loc.t("msg.sjisFailed")) }

        let replacement: Data = {
            if fallback == .substitute, let custom = substitute.data(using: shiftJis, allowLossyConversion: false) {
                return custom
            }
            return Data("?".utf8)
        }()

        var output = Data()
        for character in text {
            if let encoded = String(character).data(using: shiftJis, allowLossyConversion: false) {
                output.append(encoded)
            } else {
                output.append(replacement)
            }
        }
        return (output, true)
    }
}
