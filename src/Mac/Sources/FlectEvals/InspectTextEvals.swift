import Darwin
import Foundation
import FlectCore
import FlectKit

enum InspectTextEvals {
    static func value(_ report: FileReport, _ key: String) throws -> String {
        for fact in report.overview + report.sections.flatMap(\.rows) where fact.key == key { return fact.value }
        throw EvalFailure(description: "missing \(key) in \(report.sections.map(\.title))")
    }

    static func write(_ path: String, _ text: String, bom: Bool = false) throws {
        try ((bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)).write(to: URL(fileURLWithPath: path))
    }

    static func setAttribute(_ path: String, _ name: String, _ data: Data) throws {
        let result = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        try expect(result == 0, "setxattr \(name) failed: \(errno)")
    }

    static func stamp(_ path: String) throws -> (Data, Date) {
        let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        return (try Data(contentsOf: URL(fileURLWithPath: path)), modified ?? .distantPast)
    }

    static func portableExecutable() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x58 + 0xF0)
        bytes[0] = UInt8(ascii: "M")
        bytes[1] = UInt8(ascii: "Z")
        bytes[0x3C] = 0x40
        bytes[0x40] = UInt8(ascii: "P")
        bytes[0x41] = UInt8(ascii: "E")
        bytes[0x44] = 0x64
        bytes[0x45] = 0x86
        bytes[0x54] = 0xF0
        bytes[0x56] = 0x22
        bytes[0x58] = 0x0B
        bytes[0x59] = 0x02
        bytes[0x9C] = 3
        bytes[0xC4] = 16
        return Data(bytes)
    }

    static func register(_ suite: Suite) {
        suite.test("Analyze reads text, JSON and the download origin without rewriting the file") {
            let folder = try Paths.folder("inspect-text")
            let json = Paths.join(folder, "data.json")
            try write(json, "{\"b\":1,\"a\":[2,3]}\n")
            let lines = Paths.join(folder, "notes.txt")
            try write(lines, "a\r\nb\r\n", bom: true)
            let csv = Paths.join(folder, "table.csv")
            try write(csv, "a,b,c\n1,2,3\n")
            let ini = Paths.join(folder, "app.ini")
            try write(ini, "[main]\nname=flect\ncount=2\n")
            try setAttribute(lines, "com.apple.quarantine", Data("0083;6550a1b2;Safari;".utf8))
            let froms = try PropertyListSerialization.data(
                fromPropertyList: ["https://example.test/a", "https://example.test/"], format: .binary, options: 0)
            try setAttribute(lines, "com.apple.metadata:kMDItemWhereFroms", froms)
            let paths = [json, lines, csv, ini]
            // Back-date the files so a rewrite during inspection would show up as a new modification time.
            for path in paths {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                                      ofItemAtPath: path)
            }
            let before = try paths.map(stamp)

            let jsonReport = try await Examine.inspect(json)
            try expect(try value(jsonReport, "dialog.fileAnalyze.valid") == "Yes", "valid")
            try expect(try value(jsonReport, "dialog.fileAnalyze.topLevel") == "Object", "top level")
            try expect(try value(jsonReport, "dialog.fileAnalyze.count") == "2", "count")
            try expect(try value(jsonReport, "dialog.fileAnalyze.depth") == "2", "depth")
            try expect(try value(jsonReport, "dialog.fileAnalyze.contents") == "JSON", "contents")
            try expect(jsonReport.alerts.isEmpty, "\(jsonReport.alerts)")

            let textReport = try await Examine.inspect(lines)
            try expect(try value(textReport, "dialog.fileAnalyze.newlines") == "CRLF", "line endings")
            try expect(try value(textReport, "dialog.fileAnalyze.lines") == "2", "lines")
            try expect(try value(textReport, "dialog.fileAnalyze.characters") == "6", "characters")
            try expect(try value(textReport, "dialog.fileAnalyze.bom") == "UTF-8", "bom")
            try expect(try value(textReport, "dialog.fileAnalyze.encoding") == "Unicode (UTF-8)",
                       (try? value(textReport, "dialog.fileAnalyze.encoding")) ?? "")
            try expect(try value(textReport, "dialog.fileAnalyze.zone") == "Internet (Safari)",
                       (try? value(textReport, "dialog.fileAnalyze.zone")) ?? "")
            try expect(try value(textReport, "dialog.fileAnalyze.zoneUrl") == "https://example.test/a", "origin")
            try expect(try value(textReport, "dialog.fileAnalyze.path") == URL(fileURLWithPath: lines).standardizedFileURL.path, "path")
            try expect(try value(textReport, "dialog.fileAnalyze.size").hasPrefix("9 B (9 "), "size")
            try expect(!textReport.overview.contains { $0.key == "dialog.fileAnalyze.streams" }, "quarantine listed as a stream")
            try expect(try value(textReport, "dialog.fileAnalyze.attributes") == "None",
                       (try? value(textReport, "dialog.fileAnalyze.attributes")) ?? "")
            try expect(!jsonReport.overview.contains { $0.key == "dialog.fileAnalyze.zone" }, "zone without quarantine")

            let csvReport = try await Examine.inspect(csv)
            try expect(try value(csvReport, "dialog.fileAnalyze.rows") == "2", "rows")
            try expect(try value(csvReport, "dialog.fileAnalyze.columns") == "3", "columns")
            try expect(try value(csvReport, "dialog.fileAnalyze.delimiter") == ",", "delimiter")

            let iniReport = try await Examine.inspect(ini)
            try expect(try value(iniReport, "dialog.fileAnalyze.sections") == "1", "sections")
            try expect(try value(iniReport, "dialog.fileAnalyze.keys") == "2", "keys")

            for (path, (bytes, modified)) in zip(paths, before) {
                let (afterBytes, afterModified) = try stamp(path)
                try expect(afterBytes == bytes, "\(path) bytes changed")
                try expect(afterModified == modified, "\(path) modified \(modified) -> \(afterModified)")
            }
        }

        suite.test("Analyze reads XML, subtitles, broken JSON and text over the structure limit") {
            let folder = try Paths.folder("inspect-structure")
            let plist = Paths.join(folder, "Info.xml")
            try write(plist, """
                <?xml version="1.0" encoding="Shift_JIS"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict/></plist>
                """)
            let report = try await Examine.inspect(plist)
            try expect(try value(report, "dialog.fileAnalyze.wellFormed") == "Yes", (try? value(report, "dialog.fileAnalyze.wellFormed")) ?? "")
            try expect(try value(report, "dialog.fileAnalyze.root") == "plist", "root")
            try expect(try value(report, "dialog.fileAnalyze.declaredEncoding") == "Shift_JIS", "declared encoding")

            let broken = Paths.join(folder, "broken.xml")
            try write(broken, "<a x='1' x='2'><b/></a>")
            let brokenValue = try value(try await Examine.inspect(broken), "dialog.fileAnalyze.wellFormed")
            try expect(brokenValue.hasPrefix("No. ") && brokenValue.contains("redefined"), brokenValue)

            let deep = Paths.join(folder, "deep.json")
            try write(deep, String(repeating: "[", count: 100_000))
            let deepValue = try value(try await Examine.inspect(deep), "dialog.fileAnalyze.valid")
            try expect(deepValue.hasPrefix("No. "), deepValue)

            let subtitles = Paths.join(folder, "clip.srt")
            try write(subtitles, "1\r\n00:00:01,000 --> 00:00:02,500\r\nHi\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000 X:1\r\nBye\r\n")
            let cues = try await Examine.inspect(subtitles)
            try expect(try value(cues, "dialog.fileAnalyze.cues") == "2", "cues")
            try expect(try value(cues, "dialog.fileAnalyze.starts") == "00:00:01,000", "starts")
            try expect(try value(cues, "dialog.fileAnalyze.ends") == "00:00:04,000", "ends")

            let large = Paths.join(folder, "large.json")
            var body = Data([0xFF, 0xFE])
            let line = Array("日本語 text\r\n".utf16)
            let lineBytes = line.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let repeats = 17 * 1024 * 1024 / lineBytes.count + 1
            body.append(contentsOf: Array([[UInt8]](repeating: lineBytes, count: repeats).joined()))
            try body.write(to: URL(fileURLWithPath: large))
            let largeReport = try await Examine.inspect(large)
            try expect(try value(largeReport, "dialog.fileAnalyze.bom") == "UTF-16 LE", "large bom")
            try expect(try value(largeReport, "dialog.fileAnalyze.newlines") == "CRLF", "large newlines")
            try expect(try value(largeReport, "dialog.fileAnalyze.lines") == Formatting.count(repeats), "large lines")
            try expect(try value(largeReport, "dialog.fileAnalyze.characters") == Formatting.count(repeats * line.count), "large characters")
            try expect(try value(largeReport, "dialog.fileAnalyze.tooLarge") == Loc.t("dialog.fileAnalyze.tooLargeBody"), "large note")
        }

        suite.test("Analyze calls out executable bytes behind an image extension") {
            let folder = try Paths.folder("inspect-pe")
            let path = Paths.join(folder, "note.png")
            try portableExecutable().write(to: URL(fileURLWithPath: path))

            let report = try await Examine.inspect(path)

            try expect(report.alerts.contains { $0.contains("PNG") && $0.contains("PE") }, "\(report.alerts)")
            try expect(report.alerts.contains(Loc.f("dialog.fileAnalyze.disguise", "PNG")), "\(report.alerts)")
            try expect(try value(report, "dialog.fileAnalyze.runtime") == "Native", "runtime")
            try expect(try value(report, "dialog.fileAnalyze.signature") == "No", "signature")
            try expect(try value(report, "dialog.fileAnalyze.machine") == "AMD64", "machine")
            try expect(try value(report, "dialog.fileAnalyze.subsystem") == "Console", "subsystem")
            try expect(try value(report, "dialog.fileAnalyze.contents") == "PE", "contents")
        }

        suite.test("Analyze reads a Windows shortcut target") {
            let folder = try Paths.folder("inspect-lnk")
            let path = Paths.join(folder, "tool.lnk")
            var bytes = [UInt8](repeating: 0, count: 0x4C)
            bytes[0] = 0x4C
            for (index, value) in [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0, 0, 0, 0, 0, 0, 0x46].enumerated() {
                bytes[4 + index] = UInt8(value)
            }
            bytes[0x14] = 0x02 | 0x20
            let target = Array("C:\\Tools\\run.exe".utf8) + [0]
            var info = [UInt8](repeating: 0, count: 0x1C)
            info[4] = 0x1C
            info[8] = 0x01
            info[16] = 0x1C
            info += target
            info[0] = UInt8(info.count)
            bytes += info
            let arguments = Array("--fast".utf16)
            bytes += [UInt8(arguments.count), 0] + arguments.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            try Data(bytes).write(to: URL(fileURLWithPath: path))

            let report = try await Examine.inspect(path)
            try expect(try value(report, "dialog.fileAnalyze.target") == "C:\\Tools\\run.exe", (try? value(report, "dialog.fileAnalyze.target")) ?? "")
            try expect(try value(report, "dialog.fileAnalyze.arguments") == "--fast", "arguments")
            try expect(try value(report, "dialog.fileAnalyze.contents") == "LNK", "contents")
        }
    }
}
