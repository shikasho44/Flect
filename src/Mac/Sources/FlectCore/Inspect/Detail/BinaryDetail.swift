import Foundation
import FlectKit

// Ported from src/App/Inspect/Detail/BinaryDetail.cs: Windows PE headers and .lnk shortcut targets, read as bytes.
enum BinaryDetail {
    static func pe(_ path: String) throws -> ProbeResult? {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FlectError(Loc.t("dialog.fileAnalyze.single")) }
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }

        if length < 0x40 { return nil }
        let dos = try bytes(0, 0x40)
        guard dos.count == 0x40, uint16(dos, 0) == 0x5A4D else { return nil }
        let offset = Int(Signature.int32(dos, at: 0x3C))
        if offset <= 0 || offset > length - 24 { return nil }
        // Signature, file header and as much of the optional header as is read below.
        let header = try bytes(offset, 24 + 256)
        guard uint32(header, 0) == 0x00004550 else { return nil }
        let machine = uint16(header, 4)
        let optionalSize = Int(uint16(header, 20))
        let characteristics = uint16(header, 22)
        let optional = offset + 24
        if optionalSize < 2 || optional + 2 > length { return nil }
        let plus = uint16(header, 24) == 0x20B
        var subsystem: UInt16 = 0
        if optional + 70 <= length, optionalSize >= 70 { subsystem = uint16(header, 24 + 68) }

        var certificate: UInt32 = 0
        var runtime: UInt32 = 0
        let directory = plus ? 112 : 96
        if optionalSize >= directory + 15 * 8, optional + directory + 15 * 8 <= length {
            certificate = uint32(header, 24 + directory + 4 * 8 + 4)
            runtime = uint32(header, 24 + directory + 14 * 8 + 4)
        }

        let bag = FactBag()
        bag.add("dialog.fileAnalyze.machine", self.machine(machine))
        bag.add("dialog.fileAnalyze.subsystem", self.subsystem(subsystem))
        bag.add("dialog.fileAnalyze.runtime", Loc.t(runtime > 0 ? "dialog.fileAnalyze.dotnet" : "dialog.fileAnalyze.native"))
        bag.add("dialog.fileAnalyze.signature", Kinds.yesNo(certificate > 0))
        if characteristics & 0x2000 != 0 { bag.add("dialog.fileAnalyze.nativeLibrary", Kinds.yesNo(true)) }
        return bag.result("dialog.fileAnalyze.executable", kind: "PE", executable: true)
    }

    static func link(_ path: String) throws -> ProbeResult? {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw FlectError(Loc.t("dialog.fileAnalyze.single")) }
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        if length < 0x4C || length > 1024 * 1024 { return nil }
        try handle.seek(toOffset: 0)
        let data = [UInt8](try handle.readToEnd() ?? Data())
        guard data.count >= 0x4C, uint32(data, 0) == 0x4C else { return nil }
        let flags = uint32(data, 0x14)
        var cursor = 0x4C
        if flags & 0x1 != 0 {
            if cursor + 2 > data.count { return nil }
            cursor += 2 + Int(uint16(data, cursor))
        }

        var target: String?
        if flags & 0x2 != 0 {
            if cursor + 4 > data.count { return nil }
            let infoSize = Int(Signature.int32(data, at: cursor))
            if infoSize < 0 || cursor + infoSize > data.count { return nil }
            target = localPath(data, cursor)
            cursor += infoSize
        }

        var relative: String?
        var directory: String?
        var arguments: String?
        if flags & 0x4 != 0 { _ = readString(data, &cursor) }
        if flags & 0x8 != 0 { relative = readString(data, &cursor) }
        if flags & 0x10 != 0 { directory = readString(data, &cursor) }
        if flags & 0x20 != 0 { arguments = readString(data, &cursor) }

        let bag = FactBag()
        let blank = target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        bag.add("dialog.fileAnalyze.target", blank ? relative : target)
        bag.add("dialog.fileAnalyze.arguments", arguments)
        bag.add("dialog.fileAnalyze.workingDirectory", directory)
        guard let section = bag.section("dialog.fileAnalyze.shortcut") else { return nil }
        return ProbeResult(kind: "LNK", executable: true, sections: [section])
    }

    private static func localPath(_ data: [UInt8], _ start: Int) -> String? {
        if start + 28 > data.count { return nil }
        let headerSize = uint32(data, start + 4)
        let flags = uint32(data, start + 8)
        if flags & 0x1 == 0 { return nil }
        let offset = uint32(data, start + 16)
        let unicode = headerSize >= 0x24 ? uint32(data, start + 28) : 0
        if unicode != 0 { return readZ(data, start + Int(unicode), unicode: true) }
        if offset == 0 { return nil }
        return readZ(data, start + Int(offset), unicode: false)
    }

    private static func readZ(_ data: [UInt8], _ start: Int, unicode: Bool) -> String? {
        if start < 0 || start >= data.count { return nil }
        if !unicode {
            var end = start
            while end < data.count, data[end] != 0 { end += 1 }
            let bytes = Data(data[start..<end])
            return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252)
        }
        var end = start
        while end + 1 < data.count, data[end] != 0 || data[end + 1] != 0 { end += 2 }
        return String(data: Data(data[start..<end]), encoding: .utf16LittleEndian)
    }

    private static func readString(_ data: [UInt8], _ cursor: inout Int) -> String? {
        if cursor + 2 > data.count { return nil }
        let count = Int(uint16(data, cursor)) * 2
        cursor += 2
        if cursor + count > data.count { return nil }
        let text = String(data: Data(data[cursor..<cursor + count]), encoding: .utf16LittleEndian)
        cursor += count
        return text
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, bytes.count >= offset + 2 else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bitPattern: Signature.int32(bytes, at: offset))
    }

    private static func machine(_ machine: UInt16) -> String {
        switch machine {
        case 0x14C: return "x86"
        case 0x8664: return "AMD64"
        case 0xAA64: return "ARM64"
        case 0x1C0: return "ARM"
        case 0x1C4: return "ARM Thumb-2"
        default: return String(format: "0x%04X", machine)
        }
    }

    private static func subsystem(_ subsystem: UInt16) -> String {
        switch subsystem {
        case 1: return Loc.t("dialog.fileAnalyze.subsystemNative")
        case 2: return Loc.t("dialog.fileAnalyze.subsystemGui")
        case 3: return Loc.t("dialog.fileAnalyze.subsystemConsole")
        case 5: return "OS/2"
        case 7: return "POSIX"
        case 9: return "Windows CE"
        case 10: return "EFI application"
        case 11: return "EFI boot"
        case 12: return "EFI runtime"
        case 16: return "Windows boot"
        default: return String(subsystem)
        }
    }
}
