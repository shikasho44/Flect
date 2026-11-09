import Compression
import Foundation
import FlectKit

// Ported from src/App/Inspect/Detail/ArchiveDetail.cs. ZIP and JAR are read from the central directory;
// everything else is listed with bsdtar, which stands in for 7-Zip on the Mac.
enum ArchiveDetail {
    private static let topCount = 15

    private struct ZipEntry {
        let name: String
        let flags: Int
        let method: Int
        let packed: Int
        let size: Int
        let offset: Int
    }

    static func read(_ path: String, _ detected: String) async throws -> ProbeResult? {
        let lower = path.lowercased()
        if detected == "ZIP" || detected == "JAR" || lower.hasSuffix(".zip") || lower.hasSuffix(".jar") {
            if let zip = try readZip(path) { return zip }
        }
        return try await readListing(path, detected)
    }

    // MARK: - ZIP and JAR

    private static func readZip(_ path: String) throws -> ProbeResult? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        return try data.withUnsafeBytes { bytes -> ProbeResult? in
            guard let entries = centralDirectory(bytes, path) else { return nil }
            var files = 0
            var folders = 0
            var unpacked = 0
            var packed = 0
            var classes = 0
            var others = 0
            var signed = false
            var encrypted = false
            var minClass: Int?
            var maxClass: Int?
            var top: [(path: String, size: Int)] = []
            var mainClass: String?
            var title: String?
            var version: String?
            var manifest = false

            for entry in entries {
                try Task.checkCancellation()
                if entry.flags & 1 != 0 { encrypted = true }
                let name = entry.name.replacingOccurrences(of: "\\", with: "/")
                if name.hasSuffix("/") {
                    folders += 1
                    continue
                }

                files += 1
                unpacked += entry.size
                packed += entry.packed
                consider(&top, name, entry.size)

                let upper = name.uppercased()
                if upper == "META-INF/MANIFEST.MF" {
                    manifest = true
                    if var text = content(bytes, entry, limit: min(entry.size, 16 << 20)) {
                        if text.starts(with: [0xEF, 0xBB, 0xBF]) { text.removeFirst(3) }
                        (mainClass, title, version) = parseManifest(String(decoding: text, as: UTF8.self))
                    }
                } else if upper.hasSuffix(".CLASS") {
                    classes += 1
                    if let major = classMajor(bytes, entry) {
                        minClass = min(minClass ?? major, major)
                        maxClass = max(maxClass ?? major, major)
                    }
                } else {
                    others += 1
                }
                if upper.hasPrefix("META-INF/"), upper.hasSuffix(".SF") { signed = true }
            }

            let detected = manifest || path.lowercased().hasSuffix(".jar") ? "JAR" : "ZIP"
            let bag = FactBag()
            bag.add("dialog.fileAnalyze.format", detected)
            bag.add("dialog.fileAnalyze.encrypted", Kinds.yesNo(encrypted))
            bag.add("dialog.fileAnalyze.files", String(files))
            bag.add("dialog.fileAnalyze.folders", String(folders))
            bag.add("dialog.fileAnalyze.uncompressed", Formatting.bytes(Int64(unpacked)))
            bag.add("dialog.fileAnalyze.packed", Formatting.bytes(Int64(packed)))
            bag.add("dialog.fileAnalyze.ratio", ratio(packed, unpacked))
            largest(bag, top)

            var sections: [FileSection] = []
            if let archive = bag.section("dialog.fileAnalyze.archive") { sections.append(archive) }
            if detected == "JAR" {
                let jar = FactBag()
                jar.add("dialog.fileAnalyze.manifest", Kinds.yesNo(manifest))
                jar.add("dialog.fileAnalyze.mainClass", mainClass)
                jar.add("dialog.fileAnalyze.metaTitle", title)
                jar.add("dialog.fileAnalyze.implVersion", version)
                jar.add("dialog.fileAnalyze.classes", String(classes))
                jar.add("dialog.fileAnalyze.otherEntries", String(others))
                jar.add("dialog.fileAnalyze.bytecode", bytecode(minClass, maxClass))
                jar.add("dialog.fileAnalyze.signed", Kinds.yesNo(signed))
                if let section = jar.section("dialog.fileAnalyze.jar") { sections.append(section) }
            }
            return ProbeResult(kind: detected, sections: sections)
        }
    }

    private static func centralDirectory(_ bytes: UnsafeRawBufferPointer, _ path: String) -> [ZipEntry]? {
        let length = bytes.count
        guard length >= 22 else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func u64(_ at: Int) -> Int { bytes[at + 7] >= 0x80 ? -1 : u32(at) | u32(at + 4) << 32 }

        var end = -1
        var index = length - 22
        while index >= max(0, length - 22 - 65_535) {
            if u32(index) == 0x0605_4B50 {
                end = index
                break
            }
            index -= 1
        }
        guard end >= 0 else { return nil }

        var count = u16(end + 10)
        var size = u32(end + 12)
        var offset = u32(end + 16)
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF, end >= 20, u32(end - 20) == 0x0706_4B50 {
            let record = u64(end - 12)
            guard record >= 0, record <= length - 56, u32(record) == 0x0606_4B50 else { return nil }
            count = u64(record + 32)
            size = u64(record + 40)
            offset = u64(record + 48)
        }
        guard count >= 0, size >= 0, offset >= 0, offset <= length, size <= length - offset else { return nil }

        var legacy: String.Encoding??
        func decode(_ raw: Data, _ flags: Int) -> String {
            if let text = String(data: raw, encoding: .utf8) { return text }
            if flags & 0x0800 == 0 {
                if legacy == nil { legacy = legacyEncoding(path) }
                if let encoding = legacy ?? nil, let text = String(data: raw, encoding: encoding) { return text }
            }
            return String(decoding: raw, as: UTF8.self)
        }

        var entries: [ZipEntry] = []
        var cursor = offset
        let limit = offset + size
        for _ in 0..<count {
            guard cursor <= limit - 46, u32(cursor) == 0x0201_4B50 else { return nil }
            let flags = u16(cursor + 8)
            let nameLength = u16(cursor + 28)
            let extraLength = u16(cursor + 30)
            let commentLength = u16(cursor + 32)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= limit else { return nil }

            var packed = u32(cursor + 20)
            var unpacked = u32(cursor + 24)
            var local = u32(cursor + 42)
            if packed == 0xFFFF_FFFF || unpacked == 0xFFFF_FFFF || local == 0xFFFF_FFFF {
                var extra = cursor + 46 + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let id = u16(extra)
                    let fieldEnd = min(extra + 4 + u16(extra + 2), extraEnd)
                    if id == 0x0001 {
                        var field = extra + 4
                        if unpacked == 0xFFFF_FFFF, field + 8 <= fieldEnd { unpacked = u64(field); field += 8 }
                        if packed == 0xFFFF_FFFF, field + 8 <= fieldEnd { packed = u64(field); field += 8 }
                        if local == 0xFFFF_FFFF, field + 8 <= fieldEnd { local = u64(field) }
                        break
                    }
                    extra = fieldEnd
                }
            }
            guard packed >= 0, unpacked >= 0, local >= 0 else { return nil }

            let raw = Data(UnsafeRawBufferPointer(rebasing: bytes[(cursor + 46)..<(cursor + 46 + nameLength)]))
            entries.append(ZipEntry(name: decode(raw, flags), flags: flags, method: u16(cursor + 10),
                                    packed: packed, size: unpacked, offset: local))
            cursor = next
        }
        return entries
    }

    private static func legacyEncoding(_ path: String) -> String.Encoding? {
        let encoding: CFStringEncoding
        switch ZipNames.legacyCharset(path) {
        case "CP932": encoding = CFStringConvertIANACharSetNameToEncoding("windows-31j" as CFString)
        case "CP936": encoding = CFStringConvertIANACharSetNameToEncoding("gbk" as CFString)
        default: encoding = CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)
        }
        return encoding == kCFStringEncodingInvalidId ? nil
            : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    private static func content(_ bytes: UnsafeRawBufferPointer, _ entry: ZipEntry, limit: Int) -> Data? {
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        let local = entry.offset
        guard entry.flags & 1 == 0, local <= bytes.count - 30, u16(local) == 0x4B50, u16(local + 2) == 0x0403 else { return nil }
        let start = local + 30 + u16(local + 26) + u16(local + 28)
        guard start <= bytes.count, entry.packed <= bytes.count - start else { return nil }
        let source = UnsafeRawBufferPointer(rebasing: bytes[start..<(start + entry.packed)])
        switch entry.method {
        case 0: return Data(UnsafeRawBufferPointer(rebasing: source.prefix(limit)))
        case 8: return inflate(source, limit: limit)
        default: return nil
        }
    }

    private static func inflate(_ source: UnsafeRawBufferPointer, limit: Int) -> Data? {
        guard limit > 0, let base = source.baseAddress else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }

        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: limit)
        defer { output.deallocate() }
        stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = source.count
        stream.pointee.dst_ptr = output
        stream.pointee.dst_size = limit
        while true {
            let before = stream.pointee.dst_size + stream.pointee.src_size
            let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            if status == COMPRESSION_STATUS_ERROR { return nil }
            if status == COMPRESSION_STATUS_END || stream.pointee.dst_size == 0 { break }
            if stream.pointee.dst_size + stream.pointee.src_size == before { break }
        }
        return Data(bytes: output, count: limit - stream.pointee.dst_size)
    }

    private static func classMajor(_ bytes: UnsafeRawBufferPointer, _ entry: ZipEntry) -> Int? {
        guard let header = content(bytes, entry, limit: 8), header.count >= 8 else { return nil }
        let value = [UInt8](header.prefix(8))
        guard value[0] == 0xCA, value[1] == 0xFE, value[2] == 0xBA, value[3] == 0xBE else { return nil }
        return Int(value[6]) << 8 | Int(value[7])
    }

    private static func parseManifest(_ text: String) -> (main: String?, title: String?, version: String?) {
        var map: [String: String] = [:]
        var key: String?
        var value = ""
        for raw in lines(text) {
            if raw.hasPrefix(" "), key != nil {
                value += raw.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            if let key { map[key.lowercased()] = value }
            guard let split = raw.firstIndex(of: ":"), split > raw.startIndex else {
                key = nil
                value = ""
                continue
            }
            key = raw[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
            value = raw[raw.index(after: split)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let key { map[key.lowercased()] = value }
        return (map["main-class"], map["implementation-title"], map["implementation-version"])
    }

    private static func bytecode(_ low: Int?, _ high: Int?) -> String? {
        guard let low, let high else { return nil }
        return low == high ? "\(low) (\(java(low)))" : "\(low)-\(high) (\(java(low)) - \(java(high)))"
    }

    private static func java(_ major: Int) -> String { major >= 45 ? "Java \(major - 44)" : "major \(major)" }

    // MARK: - Other archives (bsdtar)

    private static func readListing(_ path: String, _ kind: String) async throws -> ProbeResult? {
        var arguments = ["-t", "-v", "-v", "-f", path]
        if kind == "ZIP" || path.lowercased().hasSuffix(".zip"), let charset = ZipNames.legacyCharset(path) {
            arguments += ["--options", "hdrcharset=\(charset)"]
        }
        let result = try await ProcessRunner.run(Tools.tar, arguments, environment: ["LC_ALL": "en_US.UTF-8"], background: true)
        let pattern = try NSRegularExpression(
            pattern: #"^([-a-zA-Z])\S{9}\S?\s+\d+\s+.*?\s(\d+|\d+,\d+) [A-Z][a-z]{2} +\d{1,2} +(?:\d{1,2}:\d{2}|\d{4}) (.*)$"#)

        var format: String?
        var filter: String?
        var files = 0
        var folders = 0
        var unpacked = 0
        var top: [(path: String, size: Int)] = []
        for line in lines(result.standardOutput) {
            if line.hasPrefix("Archive Format: ") {
                let parts = line.dropFirst(16).components(separatedBy: ",  Compression: ")
                format = parts[0]
                filter = parts.count > 1 ? parts[1] : nil
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let typeRange = Range(match.range(at: 1), in: line),
                  let sizeRange = Range(match.range(at: 2), in: line),
                  let nameRange = Range(match.range(at: 3), in: line) else { continue }
            let type = line[typeRange]
            if type == "d" {
                folders += 1
                continue
            }
            var name = String(line[nameRange])
            if type == "l", let link = name.range(of: " -> ") { name = String(name[..<link.lowerBound]) }
            if type == "h", let link = name.range(of: " link to ") { name = String(name[..<link.lowerBound]) }
            let size = Int(line[sizeRange]) ?? 0
            files += 1
            unpacked += size
            consider(&top, name, size)
        }

        let encrypted = result.standardError.range(of: "encrypt", options: .caseInsensitive) != nil
        if files == 0, folders == 0, format == nil, !encrypted { return gzip(path) }

        let label = label(format, filter)
        let bag = FactBag()
        bag.add("dialog.fileAnalyze.format", label ?? kind)
        bag.add("dialog.fileAnalyze.encrypted", Kinds.yesNo(encrypted))
        if files > 0 || folders > 0 || !encrypted {
            let packed = fileSize(path)
            bag.add("dialog.fileAnalyze.files", String(files))
            bag.add("dialog.fileAnalyze.folders", String(folders))
            bag.add("dialog.fileAnalyze.uncompressed", Formatting.bytes(Int64(unpacked)))
            bag.add("dialog.fileAnalyze.packed", Formatting.bytes(Int64(packed)))
            bag.add("dialog.fileAnalyze.ratio", ratio(packed, unpacked))
            largest(bag, top)
        }
        let detected = label == "RAR5" ? "RAR" : label
        return bag.result("dialog.fileAnalyze.archive", kind: detected ?? (kind.isEmpty ? "ARCHIVE" : kind))
    }

    private static func label(_ format: String?, _ filter: String?) -> String? {
        guard let format else { return nil }
        let lower = format.lowercased()
        if lower.hasPrefix("7-zip") { return "7Z" }
        if lower.hasPrefix("rar5") { return "RAR5" }
        if lower.hasPrefix("rar") { return "RAR" }
        if lower.hasPrefix("zip") { return "ZIP" }
        if lower.hasPrefix("iso9660") { return "ISO" }
        if lower.contains("tar") || lower.contains("pax") {
            guard let filter, filter != "none" else { return "TAR" }
            let suffix = ["gzip": "GZ", "bzip2": "BZ2", "xz": "XZ", "zstd": "ZST", "compress (.Z)": "Z"][filter]
            return "TAR." + (suffix ?? filter.split(separator: " ").first.map { $0.uppercased() } ?? filter.uppercased())
        }
        return format.split(separator: " ").first.map { $0.uppercased() }
    }

    // A bare .gz holds one stream that bsdtar will not list; its name and size are in the header and trailer.
    private static func gzip(_ path: String) -> ProbeResult? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 65_536).map({ [UInt8]($0) }), head.count >= 18,
              head[0] == 0x1F, head[1] == 0x8B, head[2] == 8,
              let length = try? handle.seekToEnd(), length >= 18,
              (try? handle.seek(toOffset: length - 4)) != nil,
              let trailer = try? handle.read(upToCount: 4).map({ [UInt8]($0) }), trailer.count == 4 else { return nil }

        let flags = head[3]
        var cursor = 10
        if flags & 0x04 != 0, cursor + 2 <= head.count { cursor += 2 + (Int(head[cursor]) | Int(head[cursor + 1]) << 8) }
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if flags & 0x08 != 0, cursor < head.count, let zero = head[cursor...].firstIndex(of: 0) {
            let raw = Data(head[cursor..<zero])
            if let stored = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1), !stored.isEmpty {
                name = stored
            }
        }
        let size = Int(trailer[0]) | Int(trailer[1]) << 8 | Int(trailer[2]) << 16 | Int(trailer[3]) << 24
        let packed = Int(length)

        let bag = FactBag()
        bag.add("dialog.fileAnalyze.format", "GZIP")
        bag.add("dialog.fileAnalyze.encrypted", Kinds.yesNo(false))
        bag.add("dialog.fileAnalyze.files", "1")
        bag.add("dialog.fileAnalyze.folders", "0")
        bag.add("dialog.fileAnalyze.uncompressed", Formatting.bytes(Int64(size)))
        bag.add("dialog.fileAnalyze.packed", Formatting.bytes(Int64(packed)))
        bag.add("dialog.fileAnalyze.ratio", ratio(packed, size))
        largest(bag, [(name, size)])
        return bag.result("dialog.fileAnalyze.archive", kind: "GZIP")
    }

    // MARK: - Shared

    private static func largest(_ bag: FactBag, _ top: [(path: String, size: Int)]) {
        if top.isEmpty { return }
        let ordered = top.enumerated().sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }
        bag.add("dialog.fileAnalyze.largest",
                ordered.map { "\(Formatting.bytes(Int64($0.element.size)))  \($0.element.path)" }.joined(separator: "\n"))
    }

    private static func consider(_ top: inout [(path: String, size: Int)], _ path: String, _ size: Int) {
        if top.count < topCount {
            top.append((path, size))
            return
        }
        var index = 0
        for item in 1..<top.count where top[item].size < top[index].size { index = item }
        if size > top[index].size { top[index] = (path, size) }
    }

    private static func ratio(_ packed: Int, _ unpacked: Int) -> String? {
        guard unpacked > 0 else { return nil }
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), Double(packed) / Double(unpacked) * 100)
    }

    private static func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func lines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { scalars in
            var line = String(String.UnicodeScalarView(scalars))
            while line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
            return line
        }
    }
}
