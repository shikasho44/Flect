import Foundation
import FlectKit

public indirect enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (left: JSONValue, right: JSONValue) -> Bool {
        switch (left, right) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    var isPrimitive: Bool {
        switch self {
        case .object, .array: return false
        default: return true
        }
    }

    var plainText: String {
        if case let .string(text) = self { return text }
        return JSONWriter.write(self, indented: false)
    }
}

public struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private let lenient: Bool

    public static func parse(_ text: String, lenient: Bool = false) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(text.utf8), lenient: lenient)
        parser.skipWhitespace()
        if parser.index >= parser.bytes.count { throw FlectError(Loc.t("msg.emptyFile")) }
        let value = try parser.parseValue()
        parser.skipWhitespace()
        if parser.index < parser.bytes.count { throw parser.failure("Unexpected data after the JSON value") }
        return value
    }

    private init(bytes: [UInt8], lenient: Bool) {
        self.bytes = bytes
        self.lenient = lenient
    }

    private func failure(_ message: String) -> FlectError {
        var line = 1
        var column = 1
        for byte in bytes[0..<min(index, bytes.count)] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return FlectError("\(message) (line \(line), column \(column)).")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x2F where lenient && index + 1 < bytes.count && bytes[index + 1] == 0x2F:
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
            case 0x2F where lenient && index + 1 < bytes.count && bytes[index + 1] == 0x2A:
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                index = min(index + 2, bytes.count)
            default:
                return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw failure("Unexpected end of JSON") }
        switch bytes[index] {
        case 0x7B: return try parseObject()
        case 0x5B: return try parseArray()
        case 0x22: return .string(try parseString())
        case 0x74: try expect("true"); return .bool(true)
        case 0x66: try expect("false"); return .bool(false)
        case 0x6E: try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func expect(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw failure("Invalid JSON value")
        }
        index += expected.count
    }

    private mutating func parseObject() throws -> JSONValue {
        index += 1
        var members: [(String, JSONValue)] = []
        var keys = Set<String>()
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x7D {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw failure("Expected a property name") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else { throw failure("Expected ':'") }
            index += 1
            let value = try parseValue()
            if !keys.insert(key).inserted { throw failure("Duplicate property \"\(key)\"") }
            members.append((key, value))
            skipWhitespace()
            guard index < bytes.count else { throw failure("Unexpected end of JSON") }
            if bytes[index] == 0x2C {
                index += 1
                skipWhitespace()
                if lenient, index < bytes.count, bytes[index] == 0x7D {
                    index += 1
                    return .object(members)
                }
                continue
            }
            if bytes[index] == 0x7D {
                index += 1
                return .object(members)
            }
            throw failure("Expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x5D {
            index += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw failure("Unexpected end of JSON") }
            if bytes[index] == 0x2C {
                index += 1
                skipWhitespace()
                if lenient, index < bytes.count, bytes[index] == 0x5D {
                    index += 1
                    return .array(items)
                }
                continue
            }
            if bytes[index] == 0x5D {
                index += 1
                return .array(items)
            }
            throw failure("Expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var output = [UInt8]()
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return String(decoding: output, as: UTF8.self)
            }
            if byte < 0x20 { throw failure("Control character in string") }
            if byte != 0x5C {
                output.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 0x22: output.append(0x22)
            case 0x5C: output.append(0x5C)
            case 0x2F: output.append(0x2F)
            case 0x62: output.append(0x08)
            case 0x66: output.append(0x0C)
            case 0x6E: output.append(0x0A)
            case 0x72: output.append(0x0D)
            case 0x74: output.append(0x09)
            case 0x75:
                var scalar = try hex4()
                if (0xD800...0xDBFF).contains(scalar), index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                    index += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                }
                let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                output.append(contentsOf: Array(String(character).utf8))
            default:
                throw failure("Invalid escape sequence")
            }
        }
        throw failure("Unterminated string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw failure("Invalid \\u escape") }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if index < bytes.count, bytes[index] == 0x2D { index += 1 }
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) || [0x2E, 0x65, 0x45, 0x2B, 0x2D].contains(bytes[index]) {
            index += 1
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !literal.isEmpty, Double(literal) != nil, literal.first != "+",
              literal.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
        else {
            index = start
            throw failure("Invalid JSON value")
        }
        return .number(literal)
    }
}

public enum JSONWriter {
    public static func write(_ value: JSONValue, indented: Bool = true) -> String {
        var output = ""
        append(value, to: &output, depth: 0, indented: indented)
        return output
    }

    private static func append(_ value: JSONValue, to output: inout String, depth: Int, indented: Bool) {
        let newline = indented ? "\n" : ""
        let pad = indented ? String(repeating: "  ", count: depth + 1) : ""
        let closingPad = indented ? String(repeating: "  ", count: depth) : ""

        switch value {
        case let .object(members):
            if members.isEmpty {
                output += "{}"
                return
            }
            output += "{" + newline
            for (position, member) in members.enumerated() {
                output += pad + quote(member.0) + (indented ? ": " : ":")
                append(member.1, to: &output, depth: depth + 1, indented: indented)
                output += (position < members.count - 1 ? "," : "") + newline
            }
            output += closingPad + "}"
        case let .array(items):
            if items.isEmpty {
                output += "[]"
                return
            }
            output += "[" + newline
            for (position, item) in items.enumerated() {
                output += pad
                append(item, to: &output, depth: depth + 1, indented: indented)
                output += (position < items.count - 1 ? "," : "") + newline
            }
            output += closingPad + "]"
        case let .string(text):
            output += quote(text)
        case let .number(literal):
            output += literal
        case let .bool(flag):
            output += flag ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    static func quote(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    output += String(format: "\\u%04X", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }
}

public enum SortJson {
    public static func sort(_ value: JSONValue, settings: JsonSortSettings) -> JSONValue {
        walk(value, settings, pinned: ExclusionFilter.split(settings.pinnedKeys), depth: 0)
    }

    private static func walk(_ value: JSONValue, _ settings: JsonSortSettings, pinned: [String], depth: Int) -> JSONValue {
        switch value {
        case let .object(members):
            if depth > 0, !settings.recursive { return value }
            return .object(order(members, settings, pinned).map { ($0.0, walk($0.1, settings, pinned: pinned, depth: depth + 1)) })
        case let .array(items):
            if depth > 0, !settings.recursive { return value }
            var walked = items.map { walk($0, settings, pinned: pinned, depth: depth + 1) }
            if settings.sortPrimitiveArrays, walked.allSatisfy(\.isPrimitive) {
                walked = arrange(walked, settings) { JSONWriter.write($0, indented: false) }
            }
            return .array(walked)
        default:
            return value
        }
    }

    private static func order(_ members: [(String, JSONValue)], _ settings: JsonSortSettings,
                              _ pinned: [String]) -> [(String, JSONValue)] {
        var head: [(String, JSONValue)] = []
        var taken = Set<String>()
        for key in pinned {
            if let member = members.first(where: { $0.0.caseInsensitiveCompare(key) == .orderedSame }),
               taken.insert(member.0).inserted {
                head.append(member)
            }
        }
        let tail = members.filter { !taken.contains($0.0) }
        return head + arrange(tail, settings) { $0.0 }
    }

    static func arrange<T>(_ items: [T], _ settings: JsonSortSettings, key: (T) -> String) -> [T] {
        let compare = comparer(settings.comparison)
        let keyed = items.enumerated().map { (offset: $0.offset, key: key($0.element), item: $0.element) }
        let sorted = keyed.sorted { left, right in
            let result = compare(left.key, right.key)
            if result == 0 { return left.offset < right.offset }
            return settings.descending ? result > 0 : result < 0
        }
        return sorted.map(\.item)
    }

    static func comparer(_ order: JsonKeyOrder) -> (String, String) -> Int {
        switch order {
        case .ignoreCase: return { ordinal($0.uppercased(), $1.uppercased()) }
        case .natural: return natural
        case .ordinal: return ordinal
        }
    }

    static func ordinal(_ left: String, _ right: String) -> Int {
        let a = Array(left.utf16)
        let b = Array(right.utf16)
        for (x, y) in zip(a, b) where x != y { return Int(x) - Int(y) }
        return a.count - b.count
    }

    static func natural(_ left: String, _ right: String) -> Int {
        let a = Array(left.utf16)
        let b = Array(right.utf16)
        var i = 0
        var j = 0

        func isDigit(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.decimalDigits.contains(scalar)
        }

        while i < a.count, j < b.count {
            if isDigit(a[i]), isDigit(b[j]) {
                let startA = i
                let startB = j
                while i < a.count, isDigit(a[i]) { i += 1 }
                while j < b.count, isDigit(b[j]) { j += 1 }

                var numberA = Array(a[startA..<i])
                var numberB = Array(b[startB..<j])
                while numberA.first == 0x30 { numberA.removeFirst() }
                while numberB.first == 0x30 { numberB.removeFirst() }
                if numberA.count != numberB.count { return numberA.count - numberB.count }
                for (x, y) in zip(numberA, numberB) where x != y { return Int(x) - Int(y) }
                continue
            }
            if a[i] != b[j] { return Int(a[i]) - Int(b[j]) }
            i += 1
            j += 1
        }
        return (a.count - i) - (b.count - j)
    }
}
