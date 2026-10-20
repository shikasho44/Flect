import Foundation
import FlectKit

enum Archive {
    private static let shownWarnings = 10
    private static let excluded = ["--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX"]

    static func fileExtension(_ format: ArchiveCompressFormat) -> String {
        switch format {
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .zip: return "zip"
        }
    }

    static func stem(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        return (name as NSString).deletingPathExtension
    }

    static func create(_ archive: String, from name: String, in parent: String, format: ArchiveCompressFormat) async throws -> [String] {
        var arguments = ["-c", "-f", archive, "--no-mac-metadata"]
        switch format {
        case .zip: arguments += ["--format", "zip", "--options", "zip:compression=deflate"]
        case .sevenZip: arguments += ["--format", "7zip", "--options", "7zip:compression=lzma2"]
        case .tar: arguments += ["--format", "pax"]
        case .tarGz: arguments += ["--format", "pax", "-z"]
        }
        arguments += excluded + ["-C", parent, name]
        return try await run(arguments)
    }

    static func extract(_ archive: String, into destination: String) async throws -> [String] {
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
        var arguments = ["-x", "-f", archive, "-C", destination]
        if (archive as NSString).pathExtension.lowercased() == "zip", let charset = ZipNames.legacyCharset(archive) {
            arguments += ["--options", "hdrcharset=\(charset)"]
        }
        do {
            return try await run(arguments)
        } catch {
            let empty = ((try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []).isEmpty
            if empty { try? FileManager.default.removeItem(atPath: destination) }
            throw error
        }
    }

    private static func run(_ arguments: [String]) async throws -> [String] {
        let result = try await ProcessRunner.run(Tools.tar, arguments, environment: ["LC_ALL": "en_US.UTF-8"],
                                                 background: true)
        let lines = result.standardError.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if result.succeeded { return lines }

        let tail = lines.suffix(3).joined(separator: " ")
        throw FlectError("tar failed (exit \(result.exitCode)). \(tail)")
    }

    static func report(_ warnings: [String], name: String, progress: TaskProgress) {
        var seen = Set<String>()
        let unique = warnings.filter { seen.insert($0).inserted }
        for line in unique.prefix(shownWarnings) { progress.warn("\(name) - \(line)") }
        if unique.count > shownWarnings {
            progress.warn("\(name) - \(Loc.f("msg.andMore", Formatting.count(unique.count - shownWarnings)))")
        }
    }
}

enum ZipNames {
    static func legacyCharset(_ path: String) -> String? {
        let names = legacyNames(path)
        if names.isEmpty { return nil }
        let candidates = Loc.current == .chineseSimplified ? ["CP936", "CP932"] : ["CP932", "CP936"]
        return candidates.first { charset in
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding((charset == "CP932" ? "windows-31j" : "gbk") as CFString)))
            return names.allSatisfy { String(data: $0, encoding: encoding) != nil }
        }
    }

    private static func legacyNames(_ path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length >= 22 else { return [] }

        let tailLength = min(UInt64(65_557), length)
        try? handle.seek(toOffset: length - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)).map({ [UInt8]($0) }) else { return [] }

        func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ bytes: [UInt8], _ at: Int) -> Int { u16(bytes, at) | u16(bytes, at + 2) << 16 }

        var end = -1
        var index = tail.count - 22
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                end = index
                break
            }
            index -= 1
        }
        guard end >= 0 else { return [] }

        let count = u16(tail, end + 10)
        let size = u32(tail, end + 12)
        let offset = u32(tail, end + 16)
        guard size > 0, UInt64(offset + size) <= length else { return [] }
        try? handle.seek(toOffset: UInt64(offset))
        guard let directory = try? handle.read(upToCount: size).map({ [UInt8]($0) }) else { return [] }

        var cursor = 0
        var names: [Data] = []
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, u32(directory, cursor) == 0x02014B50 else { break }
            let flags = u16(directory, cursor + 8)
            let nameLength = u16(directory, cursor + 28)
            let extraLength = u16(directory, cursor + 30)
            let commentLength = u16(directory, cursor + 32)
            guard cursor + 46 + nameLength <= directory.count else { break }
            let name = Data(directory[(cursor + 46)..<(cursor + 46 + nameLength)])
            if flags & 0x0800 == 0, name.contains(where: { $0 >= 0x80 }), String(data: name, encoding: .utf8) == nil {
                names.append(name)
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return names
    }
}
