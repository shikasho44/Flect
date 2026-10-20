import Foundation
import FlectKit

enum DataFormats {
    private static let delimiters: [Character] = [",", ";", "\t", "|"]
    private static let detectionWindow = 64 * 1024

    static func parse(_ source: String, _ text: String, progress: TaskProgress, path: String) throws -> JSONValue {
        switch source {
        case "JSON": return try JSONParser.parse(text)
        case "CSV": return try fromCsv(text, progress: progress, path: path)
        case "XML": return try fromXml(text)
        case "INI", "CONF", "CFG": return fromIni(text)
        default: throw FlectError(Loc.f("msg.cannotConvertFrom", source))
        }
    }

    static func render(_ tree: JSONValue, as target: String) throws -> String {
        switch target {
        case "JSON": return JSONWriter.write(tree)
        case "XML": return toXml(tree)
        case "CSV": return toCsv(try table(tree))
        case "HTML": return toHtml(try table(tree))
        case "MD": return toMarkdown(try table(tree))
        default: throw FlectError(Loc.f("msg.cannotConvertTo", target))
        }
    }

    static func detectDelimiter(_ text: String) -> Character {
        let window = String(text.prefix(detectionWindow))
        let consistent = delimiters
            .map { (candidate: $0, columns: consistentColumns(window, $0)) }
            .filter { $0.columns > 1 }

        if let quoted = quoteVote(window), consistent.contains(where: { $0.candidate == quoted }) { return quoted }
        return consistent.max { $0.columns < $1.columns }?.candidate ?? ","
    }

    private static func quoteVote(_ text: String) -> Character? {
        var votes: [Character: Int] = [:]
        var inQuotes = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            defer { index += 1 }
            guard characters[index] == "\"" else { continue }
            if !inQuotes {
                inQuotes = true
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "\"" {
                index += 1
                continue
            }
            inQuotes = false
            if index + 1 < characters.count, delimiters.contains(characters[index + 1]) {
                votes[characters[index + 1], default: 0] += 1
            }
        }
        return votes.max { $0.value < $1.value }?.key
    }

    private static func consistentColumns(_ text: String, _ delimiter: Character) -> Int {
        let rows = split(text, delimiter).filter { !($0.count == 1 && $0[0].isEmpty) }.prefix(10)
        guard let first = rows.first else { return 0 }
        return rows.allSatisfy { $0.count == first.count } ? first.count : 0
    }

    static func split(_ text: String, _ delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var any = false
        let characters = Array(text.unicodeScalars)
        let delimiterScalar = delimiter.unicodeScalars.first!
        var index = 0

        while index < characters.count {
            let scalar = characters[index]
            defer { index += 1 }

            if quoted {
                if scalar != "\"" {
                    field.unicodeScalars.append(scalar)
                } else if index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted = false
                }
                continue
            }

            if scalar == "\"" {
                quoted = true
                any = true
            } else if scalar == delimiterScalar {
                row.append(field)
                field = ""
                any = true
            } else if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                any = false
            } else {
                field.unicodeScalars.append(scalar)
                any = true
            }
        }

        if any || !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func fromCsv(_ text: String, progress: TaskProgress, path: String) throws -> JSONValue {
        let delimiter = detectDelimiter(text)
        if delimiter != "," {
            let shown = delimiter == "\t" ? Loc.t("msg.separator.tab") : String(delimiter)
            progress.info(Loc.f("msg.readAsSeparated", fileName(path), shown))
        }

        let rows = split(text, delimiter)
        guard let headers = rows.first else { throw FlectError(Loc.t("msg.emptyFile")) }

        var table: [JSONValue] = []
        for row in rows.dropFirst() {
            if row.count == 1, row[0].isEmpty { continue }
            var record: [(String, JSONValue)] = []
            var seen = Set<String>()
            for (column, header) in headers.enumerated() {
                let name = header.isEmpty ? "column\(column + 1)" : header
                let value = JSONValue.string(column < row.count ? row[column] : "")
                if seen.insert(name).inserted {
                    record.append((name, value))
                } else if let existing = record.firstIndex(where: { $0.0 == name }) {
                    record[existing].1 = value
                }
            }
            table.append(.object(record))
        }

        if table.isEmpty { throw FlectError(Loc.t("msg.noDataRows")) }
        return .array(table)
    }

    private static func table(_ tree: JSONValue) throws -> [[(String, JSONValue)]] {
        guard case let .array(items) = tree else { throw FlectError(Loc.t("msg.notATable")) }
        return try items.map { item in
            guard case let .object(members) = item else { throw FlectError(Loc.t("msg.notATable")) }
            return members
        }
    }

    private static func columns(_ rows: [[(String, JSONValue)]]) -> [String] {
        var columns: [String] = []
        var seen = Set<String>()
        for row in rows {
            for (key, _) in row where seen.insert(key).inserted { columns.append(key) }
        }
        return columns
    }

    private static func cell(_ row: [(String, JSONValue)], _ column: String) -> String {
        guard let value = row.first(where: { $0.0 == column })?.1 else { return "" }
        if case .null = value { return "" }
        return value.plainText
    }

    private static func toCsv(_ rows: [[(String, JSONValue)]]) -> String {
        func quote(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : value
        }
        let names = columns(rows)
        var text = names.map(quote).joined(separator: ",") + "\n"
        for row in rows { text += names.map { quote(cell(row, $0)) }.joined(separator: ",") + "\n" }
        return text
    }

    private static func escapeHtml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func toHtml(_ rows: [[(String, JSONValue)]]) -> String {
        let names = columns(rows)
        var html = "<!doctype html>\n"
        html += "<html><head><meta charset=\"utf-8\"><title>Table</title></head><body>\n"
        html += "<table>\n"
        html += "  <thead><tr>" + names.map { "<th>\(escapeHtml($0))</th>" }.joined() + "</tr></thead>\n"
        html += "  <tbody>\n"
        for row in rows {
            html += "    <tr>" + names.map { "<td>\(escapeHtml(cell(row, $0)))</td>" }.joined() + "</tr>\n"
        }
        html += "  </tbody>\n</table>\n</body></html>\n"
        return html
    }

    private static func toMarkdown(_ rows: [[(String, JSONValue)]]) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        let names = columns(rows)
        var markdown = "| " + names.map(escape).joined(separator: " | ") + " |\n"
        markdown += "| " + names.map { _ in "---" }.joined(separator: " | ") + " |\n"
        for row in rows { markdown += "| " + names.map { escape(cell(row, $0)) }.joined(separator: " | ") + " |\n" }
        return markdown
    }

    private static func escapeXml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func safeName(_ key: String) -> String {
        var name = String(key.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." ? $0 : "_" })
        if name.isEmpty || !(name.first!.isLetter || name.first == "_") { name.insert("_", at: name.startIndex) }
        return name
    }

    private static func toXml(_ tree: JSONValue) -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>"]

        func element(_ name: String, _ value: JSONValue, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            switch value {
            case let .object(members):
                if members.isEmpty {
                    lines.append("\(pad)<\(name) />")
                    return
                }
                lines.append("\(pad)<\(name)>")
                for (key, child) in members { element(safeName(key), child, depth: depth + 1) }
                lines.append("\(pad)</\(name)>")
            case let .array(items):
                if items.isEmpty {
                    lines.append("\(pad)<\(name) />")
                    return
                }
                lines.append("\(pad)<\(name)>")
                for item in items { element("item", item, depth: depth + 1) }
                lines.append("\(pad)</\(name)>")
            case .null:
                lines.append("\(pad)<\(name) />")
            default:
                let text = value.plainText
                lines.append(text.isEmpty ? "\(pad)<\(name) />" : "\(pad)<\(name)>\(escapeXml(text))</\(name)>")
            }
        }

        element("root", tree, depth: 0)
        return lines.joined(separator: "\n")
    }

    private static func fromXml(_ text: String) throws -> JSONValue {
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: text, options: [])
        } catch {
            throw FlectError(describe(error))
        }
        guard let root = document.rootElement() else { throw FlectError(Loc.t("msg.noRootElement")) }
        return convert(root)
    }

    private static func convert(_ element: XMLElement) -> JSONValue {
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }
        let attributes = element.attributes ?? []
        if children.isEmpty, attributes.isEmpty { return .string(element.stringValue ?? "") }

        var members: [(String, JSONValue)] = []
        for attribute in attributes {
            members.append(("@" + (attribute.localName ?? attribute.name ?? ""), .string(attribute.stringValue ?? "")))
        }

        var order: [String] = []
        var groups: [String: [XMLElement]] = [:]
        for child in children {
            let name = child.localName ?? child.name ?? ""
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(child)
        }
        for name in order {
            let items = groups[name]!
            members.append((name, items.count == 1 ? convert(items[0]) : .array(items.map(convert))))
        }

        let own = (element.children ?? []).filter { $0.kind == .text }.map { $0.stringValue ?? "" }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { members.append(("#text", .string(own))) }
        return .object(members)
    }

    private static func fromIni(_ text: String) -> JSONValue {
        var root: [(String, JSONValue)] = []
        var sections: [String: [(String, JSONValue)]] = [:]
        var sectionOrder: [String] = []
        var current: String?

        func set(_ key: String, _ value: String) {
            if let section = current {
                var members = sections[section] ?? []
                if let existing = members.firstIndex(where: { $0.0 == key }) {
                    members[existing].1 = .string(value)
                } else {
                    members.append((key, .string(value)))
                }
                sections[section] = members
            } else if let existing = root.firstIndex(where: { $0.0 == key }) {
                root[existing].1 = .string(value)
            } else {
                root.append((key, .string(value)))
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 {
                let section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if sections[section] == nil {
                    sections[section] = []
                    sectionOrder.append(section)
                    root.removeAll { $0.0 == section }
                }
                current = section
                continue
            }

            guard let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { set(key, value) }
        }

        for section in sectionOrder { root.append((section, .object(sections[section] ?? []))) }
        return .object(root)
    }
}
