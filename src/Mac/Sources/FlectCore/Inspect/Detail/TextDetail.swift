import Foundation
import FlectKit

// Ported from src/App/Inspect/Detail/TextDetail.cs. Reads only; the file is never opened for writing.
enum TextDetail {
    private static let structureLimit = 16 * 1024 * 1024
    private static let sampleSize = 64 * 1024
    private static let jsonDepthLimit = 64
    private static let structured: Set<String> = [
        "json", "xml", "html", "htm", "csv", "tsv", "md", "markdown", "ini", "cfg", "conf", "srt", "vtt",
    ]

    static func read(_ path: String, _ extension: String) throws -> ProbeResult? {
        let ext = `extension`.lowercased()
        let (sample, length) = try Self.sample(path)

        let encoding: String.Encoding
        var text: String?
        var counts: NewlineCount
        if length <= structureLimit {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let unmarked = unmarkedUtf16(sample), let decoded = String(data: data, encoding: unmarked) {
                (text, encoding) = (decoded, unmarked)
            } else {
                let (decoded, info) = try TextFile.decode(data)
                (text, encoding) = (decoded, info.encoding)
            }
            counts = NewlineCount()
            counts.feed(text!)
        } else {
            let detected = detect(sample)
            encoding = detected.encoding
            counts = try countStream(path, encoding, skip: detected.bom)
        }
        counts.finish()

        let bag = FactBag()
        bag.add("dialog.fileAnalyze.encoding", String.localizedName(of: encoding))
        bag.add("dialog.fileAnalyze.bom", bom(sample))
        bag.add("dialog.fileAnalyze.newlines", newlines(counts))
        bag.add("dialog.fileAnalyze.lines", Formatting.count(counts.lines))
        bag.add("dialog.fileAnalyze.characters", Formatting.count(counts.characters))

        var sections: [FileSection] = []
        if let section = bag.section("dialog.fileAnalyze.text") { sections.append(section) }

        var kind = "TEXT"
        if let text {
            kind = structure(ext, text, &sections) ?? kind
        } else if structured.contains(ext) {
            let note = FactBag()
            note.add("dialog.fileAnalyze.tooLarge", Loc.t("dialog.fileAnalyze.tooLargeBody"))
            if let extra = note.section(sectionKey(ext)) { sections.append(extra) }
        }
        return ProbeResult(kind: kind, sections: sections)
    }

    private static func structure(_ ext: String, _ text: String, _ sections: inout [FileSection]) -> String? {
        var kind: String?
        if ext == "json" || looksLikeJson(text) {
            sections.append(json(text))
            kind = "JSON"
        } else if ext == "xml" || text.drop(while: \.isWhitespace).prefix(5).lowercased() == "<?xml" {
            if let xml = xml(text) {
                sections.append(xml)
                kind = "XML"
            }
        }

        if ext == "csv" || ext == "tsv" {
            sections.append(csv(text, ext == "tsv" ? 0x09 : nil))
            kind = kind ?? (ext == "tsv" ? "TSV" : "CSV")
        } else if ext == "html" || ext == "htm" {
            if let html = html(text) { sections.append(html) }
            kind = "HTML"
        } else if ["ini", "cfg", "conf"].contains(ext) {
            sections.append(ini(text))
            kind = kind ?? "INI"
        } else if ext == "md" || ext == "markdown" {
            sections.append(markdown(text))
            kind = kind ?? "MD"
        } else if ext == "srt" || ext == "vtt" || looksLikeSubtitle(text) {
            if let cues = subtitles(text) {
                sections.append(cues)
                kind = kind ?? (ext == "vtt" ? "VTT" : "SRT")
            }
        }
        return kind
    }

    // MARK: - Structure

    private static func json(_ text: String) -> FileSection {
        let bag = FactBag()
        do {
            if nesting(text) > jsonDepthLimit {
                throw FlectError("The maximum depth of \(jsonDepthLimit) was exceeded.")
            }
            let root = try JSONParser.parse(text)
            bag.add("dialog.fileAnalyze.valid", Kinds.yesNo(true))
            bag.add("dialog.fileAnalyze.topLevel", top(root))
            switch root {
            case let .object(members): bag.add("dialog.fileAnalyze.count", String(members.count))
            case let .array(items): bag.add("dialog.fileAnalyze.count", String(items.count))
            default: break
            }
            bag.add("dialog.fileAnalyze.depth", String(depth(root)))
        } catch {
            bag.add("dialog.fileAnalyze.valid", Loc.f("dialog.fileAnalyze.invalid", error.localizedDescription))
        }
        return bag.section("dialog.fileAnalyze.jsonSection")!
    }

    // Like the XmlReader it replaces, this reads up to the root element. A DOCTYPE is blanked out first,
    // so no DTD or entity is ever loaded, and XML property lists still read as well-formed.
    private static func xml(_ text: String) -> FileSection? {
        let bag = FactBag()
        let data = Data(xmlSource(text).utf8)
        let parser = XMLParser(data: data)
        let finder = RootFinder()
        parser.delegate = finder
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        if let root = finder.root {
            bag.add("dialog.fileAnalyze.wellFormed", Kinds.yesNo(true))
            bag.add("dialog.fileAnalyze.root", root)
            bag.add("dialog.fileAnalyze.declaredEncoding", declaredEncoding(text))
        } else {
            bag.add("dialog.fileAnalyze.wellFormed", Loc.f("dialog.fileAnalyze.invalid", xmlError(data, parser)))
        }
        return bag.section("dialog.fileAnalyze.xmlSection")
    }

    private final class RootFinder: NSObject, XMLParserDelegate {
        var root: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            root = qualifiedName ?? elementName
            parser.abortParsing()
        }
    }

    private static func xmlError(_ data: Data, _ parser: XMLParser) -> String {
        let line = parser.lineNumber
        let column = parser.columnNumber
        do {
            _ = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
        }
        return "Line \(line), column \(column)."
    }

    // The text with its declared encoding set to UTF-8 (it is parsed as UTF-8 bytes) and any DOCTYPE
    // replaced by spaces, keeping line numbers.
    private static func xmlSource(_ text: String) -> String {
        var units = Array(text.utf16)
        var index = 0
        func skipSpace() { while index < units.count, [0x20, 0x09, 0x0D, 0x0A].contains(units[index]) { index += 1 } }
        func starts(_ prefix: String) -> Bool {
            var at = index
            for unit in prefix.utf16 {
                guard at < units.count, units[at] == unit else { return false }
                at += 1
            }
            return true
        }
        func skip(past end: String) {
            let first = end.utf16.first!
            while index < units.count, units[index] != first || !starts(end) { index += 1 }
            index = min(index + end.utf16.count, units.count)
        }

        var declaration: Range<Int>?
        while true {
            skipSpace()
            if starts("<?") {
                let start = index
                skip(past: "?>")
                if start == 0 { declaration = start..<index }
            } else if starts("<!--") {
                skip(past: "-->")
            } else if starts("<!DOCTYPE") {
                let start = index
                var quote: UInt16?
                var subset = false
                while index < units.count {
                    let unit = units[index]
                    index += 1
                    if let open = quote {
                        if unit == open { quote = nil }
                    } else if unit == 0x22 || unit == 0x27 {
                        quote = unit
                    } else if unit == 0x5B {
                        subset = true
                    } else if unit == 0x5D {
                        subset = false
                    } else if unit == 0x3E, !subset {
                        break
                    }
                }
                for blank in start..<index where units[blank] != 0x0A && units[blank] != 0x0D { units[blank] = 0x20 }
            } else {
                break
            }
        }

        var source = String(decoding: units, as: UTF16.self)
        if let declaration {
            let head = String(decoding: units[declaration], as: UTF16.self)
            let fixed = head.replacingOccurrences(of: #"(encoding\s*=\s*["'])[^"']*(["'])"#, with: "$1UTF-8$2",
                                                  options: .regularExpression)
            source = fixed + String(decoding: units[declaration.upperBound...], as: UTF16.self)
        }
        return source
    }

    private static func csv(_ text: String, _ forced: UInt16?) -> FileSection {
        let delimiter = forced ?? self.delimiter(text)
        let (rows, columns) = measure(text, delimiter)
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.delimiter",
                delimiter == 0x09 ? Loc.t("dialog.fileAnalyze.tab") : String(decoding: [delimiter], as: UTF16.self))
        bag.add("dialog.fileAnalyze.rows", Formatting.count(rows))
        bag.add("dialog.fileAnalyze.columns", String(columns))
        return bag.section("dialog.fileAnalyze.csvSection")!
    }

    private static func html(_ text: String) -> FileSection? {
        let bag = FactBag()
        if let title = match(text, #"<title[^>]*>(.*?)</title>"#, [.caseInsensitive, .dotMatchesLineSeparators]) {
            bag.add("dialog.fileAnalyze.metaTitle", title)
        }
        if let charset = match(text, #"charset\s*=\s*["']?\s*([^"'>\s]+)"#, [.caseInsensitive]) {
            bag.add("dialog.fileAnalyze.declaredEncoding", charset)
        }
        return bag.section("dialog.fileAnalyze.htmlSection")
    }

    private static func ini(_ text: String) -> FileSection {
        var sections = 0
        var keys = 0
        for raw in lines(text) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                sections += 1
            } else if line.contains("=") || line.contains(":") {
                keys += 1
            }
        }
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.sections", String(sections))
        bag.add("dialog.fileAnalyze.keys", String(keys))
        return bag.section("dialog.fileAnalyze.iniSection")!
    }

    private static func markdown(_ text: String) -> FileSection {
        var headings = 0
        for raw in lines(text) {
            let line = Array(raw.drop(while: \.isWhitespace).utf16)
            var marks = 0
            while marks < line.count, marks < 6, line[marks] == 0x23 { marks += 1 }
            if marks > 0, marks < line.count, line[marks] == 0x20 { headings += 1 }
        }
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.headings", String(headings))
        return bag.section("dialog.fileAnalyze.markdown")!
    }

    private static func subtitles(_ text: String) -> FileSection? {
        var first: String?
        var last: String?
        var cues = 0
        for raw in lines(text) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let arrow = line.range(of: "-->"), arrow.lowerBound > line.startIndex else { continue }
            cues += 1
            let start = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = line[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let end = tail.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if first == nil { first = start }
            last = end
        }
        if cues == 0 { return nil }
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.cues", String(cues))
        bag.add("dialog.fileAnalyze.starts", first)
        bag.add("dialog.fileAnalyze.ends", last)
        return bag.section("dialog.fileAnalyze.subtitle")
    }

    private static func sectionKey(_ ext: String) -> String {
        switch ext {
        case "json": return "dialog.fileAnalyze.jsonSection"
        case "xml": return "dialog.fileAnalyze.xmlSection"
        case "html", "htm": return "dialog.fileAnalyze.htmlSection"
        case "csv", "tsv": return "dialog.fileAnalyze.csvSection"
        case "md", "markdown": return "dialog.fileAnalyze.markdown"
        case "srt", "vtt": return "dialog.fileAnalyze.subtitle"
        default: return "dialog.fileAnalyze.iniSection"
        }
    }

    // MARK: - Helpers

    private static func top(_ value: JSONValue) -> String {
        switch value {
        case .object: return Loc.t("dialog.fileAnalyze.object")
        case .array: return Loc.t("dialog.fileAnalyze.array")
        case .string: return Loc.t("dialog.fileAnalyze.jsonString")
        case .number: return Loc.t("dialog.fileAnalyze.jsonNumber")
        case let .bool(flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func depth(_ value: JSONValue) -> Int {
        switch value {
        case let .object(members): return 1 + (members.map { depth($0.1) }.max() ?? 0)
        case let .array(items): return 1 + (items.map(depth).max() ?? 0)
        default: return 0
        }
    }

    // Deepest bracket nesting outside strings; checked before parsing so a hostile file cannot exhaust the stack.
    private static func nesting(_ text: String) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for unit in text.utf8 {
            if inString {
                if escaped { escaped = false } else if unit == 0x5C { escaped = true } else if unit == 0x22 { inString = false }
                continue
            }
            switch unit {
            case 0x22: inString = true
            case 0x7B, 0x5B:
                depth += 1
                deepest = max(deepest, depth)
            case 0x7D, 0x5D: depth -= 1
            default: break
            }
        }
        return deepest
    }

    private static func looksLikeJson(_ text: String) -> Bool {
        let first = text.unicodeScalars.first { !["\u{FEFF}", " ", "\t", "\r", "\n"].contains($0) }
        return first == "{" || first == "["
    }

    private static func looksLikeSubtitle(_ text: String) -> Bool {
        var count = 0
        for line in lines(text) {
            if line.contains("-->") { return true }
            count += 1
            if count > 40 { break }
        }
        return false
    }

    private static func delimiter(_ text: String) -> UInt16 {
        let line = text.utf16.prefix { $0 != 0x0A }
        var best: UInt16 = 0x2C
        var score = -1
        for candidate: UInt16 in [0x2C, 0x09, 0x3B, 0x7C] {
            let count = line.reduce(0) { $1 == candidate ? $0 + 1 : $0 }
            if count > score {
                score = count
                best = candidate
            }
        }
        return best
    }

    private static func measure(_ text: String, _ delimiter: UInt16) -> (Int, Int) {
        let units = Array(text.utf16)
        var rows = 0
        var columns = 0
        var field = 1
        var quote = false
        var any = false
        var index = 0
        while index < units.count {
            let unit = units[index]
            defer { index += 1 }
            if quote {
                if unit == 0x22 {
                    if index + 1 < units.count, units[index + 1] == 0x22 { index += 1 } else { quote = false }
                }
                any = true
                continue
            }
            if unit == 0x22 {
                quote = true
                any = true
            } else if unit == delimiter {
                field += 1
                any = true
            } else if unit == 0x0A || unit == 0x0D {
                if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                if any {
                    rows += 1
                    columns = max(columns, field)
                }
                field = 1
                any = false
            } else {
                any = true
            }
        }
        if any {
            rows += 1
            columns = max(columns, field)
        }
        return (rows, columns)
    }

    private static func declaredEncoding(_ text: String) -> String? {
        match(text, #"encoding\s*=\s*["']([^"']+)["']"#, [.caseInsensitive])
    }

    private static func match(_ text: String, _ pattern: String, _ options: NSRegularExpression.Options) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let found = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Split on LF alone, as the C# String.Split('\n') did; a Swift Character would keep "\r\n" together.
    private static func lines(_ text: String) -> [String] {
        (text as NSString).components(separatedBy: "\n")
    }

    // MARK: - Newlines

    private struct NewlineCount {
        var lines = 0
        var characters = 0
        var cr = 0
        var lf = 0
        var crlf = 0
        private var pending = false
        private var last: UInt16 = 0

        mutating func feed(_ text: String) {
            for unit in text.utf16 {
                characters += 1
                last = unit
                if unit == 0x0D {
                    if pending { cr += 1 }
                    pending = true
                } else if unit == 0x0A {
                    if pending { crlf += 1 } else { lf += 1 }
                    pending = false
                    lines += 1
                } else if pending {
                    cr += 1
                    lines += 1
                    pending = false
                }
            }
        }

        mutating func finish() {
            if pending {
                cr += 1
                lines += 1
                pending = false
            } else if characters > 0, last != 0x0A, last != 0x0D {
                lines += 1
            }
        }
    }

    // Files over the structure limit are decoded a chunk at a time, each cut after a line feed so no
    // character is split.
    private static func countStream(_ path: String, _ encoding: String.Encoding, skip: Int) throws -> NewlineCount {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FlectError(Loc.t("dialog.fileAnalyze.single")) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(skip))
        let width = unitWidth(encoding)
        var counts = NewlineCount()
        var carry = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            carry.append(chunk)
            if carry.isEmpty { break }
            let cut = chunk.isEmpty ? carry.count : boundary([UInt8](carry), encoding, width)
            if cut > 0 {
                counts.feed(decode(carry.prefix(cut), encoding))
                carry = carry.subdata(in: carry.startIndex + cut..<carry.endIndex)
            }
            if chunk.isEmpty { break }
        }
        return counts
    }

    private static func boundary(_ bytes: [UInt8], _ encoding: String.Encoding, _ width: Int) -> Int {
        let bigEndian = encoding == .utf16BigEndian || encoding == .utf32BigEndian
        var index = (bytes.count / width - 1) * width
        while index >= 0 {
            let unit = bytes[index..<index + width]
            if bigEndian ? unit.last == 0x0A && unit.dropLast().allSatisfy({ $0 == 0 })
                         : unit.first == 0x0A && unit.dropFirst().allSatisfy({ $0 == 0 }) {
                return index + width
            }
            index -= width
        }
        if bytes.count < 8 << 20 { return 0 }
        return encoding == .utf8 ? utf8Boundary(bytes) : bytes.count - bytes.count % width
    }

    // Where the bytes end before a possibly incomplete UTF-8 sequence.
    private static func utf8Boundary(_ bytes: [UInt8]) -> Int {
        var cut = bytes.count
        while cut > 0, bytes.count - cut < 4, bytes[cut - 1] & 0xC0 == 0x80 { cut -= 1 }
        if cut > 0, bytes[cut - 1] >= 0xC0 { cut -= 1 }
        return cut
    }

    private static func decode(_ data: Data, _ encoding: String.Encoding) -> String {
        if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private static func unitWidth(_ encoding: String.Encoding) -> Int {
        switch encoding {
        case .utf16, .utf16LittleEndian, .utf16BigEndian: return 2
        case .utf32, .utf32LittleEndian, .utf32BigEndian: return 4
        default: return 1
        }
    }

    // MARK: - Encoding

    private static func detect(_ sample: [UInt8]) -> (encoding: String.Encoding, bom: Int) {
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if sample.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if sample.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if sample.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if sample.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        if let unmarked = unmarkedUtf16(sample) { return (unmarked, 0) }
        let cut = sample.lastIndex(of: 0x0A).map { $0 + 1 } ?? utf8Boundary(sample)
        let encoding = (try? TextFile.decode(Data(sample.prefix(cut))))?.1.encoding ?? .utf8
        return (encoding, 0)
    }

    // UTF-16 without a byte order mark: mostly-ASCII text leaves a zero in every other byte.
    private static func unmarkedUtf16(_ sample: [UInt8]) -> String.Encoding? {
        let pairs = sample.count / 2
        guard pairs >= 2, !sample.starts(with: [0xFF, 0xFE]), !sample.starts(with: [0xFE, 0xFF]) else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for pair in 0..<pairs {
            if sample[pair * 2] == 0 { evenZeros += 1 }
            if sample[pair * 2 + 1] == 0 { oddZeros += 1 }
        }
        if oddZeros * 4 >= pairs, evenZeros * 50 <= pairs { return .utf16LittleEndian }
        if evenZeros * 4 >= pairs, oddZeros * 50 <= pairs { return .utf16BigEndian }
        return nil
    }

    private static func newlines(_ counts: NewlineCount) -> String {
        let kinds = [counts.crlf, counts.lf, counts.cr].filter { $0 > 0 }.count
        if kinds == 0 { return Loc.t("dialog.fileAnalyze.none") }
        if kinds > 1 { return Loc.t("dialog.fileAnalyze.mixed") }
        if counts.crlf > 0 { return "CRLF" }
        if counts.lf > 0 { return "LF" }
        return "CR"
    }

    private static func bom(_ sample: [UInt8]) -> String {
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) { return "UTF-8" }
        if sample.starts(with: [0xFF, 0xFE]) { return sample.starts(with: [0xFF, 0xFE, 0, 0]) ? "UTF-32 LE" : "UTF-16 LE" }
        if sample.starts(with: [0xFE, 0xFF]) { return "UTF-16 BE" }
        if sample.starts(with: [0, 0, 0xFE, 0xFF]) { return "UTF-32 BE" }
        return Loc.t("dialog.fileAnalyze.none")
    }

    private static func sample(_ path: String) throws -> ([UInt8], Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FlectError(Loc.t("dialog.fileAnalyze.single")) }
        defer { try? handle.close() }
        let sample = [UInt8](try handle.read(upToCount: sampleSize) ?? Data())
        return (sample, Int(try handle.seekToEnd()))
    }
}
