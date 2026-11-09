import Foundation
import FlectCore
import FlectKit

// Mirrors the name, checksum, report and task cases of evals/Evals/Inspect/FileTests.cs, plus the menu entry.
enum InspectCoreEvals {
    static func value(_ report: FileReport, _ label: String) throws -> String {
        for fact in report.overview + report.sections.flatMap(\.rows) where fact.label == label { return fact.value }
        throw EvalFailure(description: "missing row \(label) in \(report.sections.map(\.title))")
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

    private static func write(_ folder: String, _ name: String, _ data: Data) throws -> String {
        let path = Paths.join(folder, name)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func register(_ suite: Suite) {
        suite.test("Analyze: a right-to-left override shows the spoofed name") {
            let folder = try Paths.folder("file-rlo")
            let path = try write(folder, "evil\u{202E}gpj.exe", portableExecutable())
            let report = try await Examine.inspect(path)
            try expect(report.alerts.contains { $0.contains("RLO") }, "\(report.alerts)")
            try expect(report.alerts.contains { $0.contains("JPEG") }, "\(report.alerts)")
            let shown = try value(report, "Shown name")
            try expect(shown == "evilexe.jpg", shown)
            try expect(try value(report, "Contents") == "PE", "contents")
            try expect(try value(report, "Machine") == "AMD64", "machine")
            try expect(try value(report, "Subsystem") == "Console", "subsystem")
            try expect(!report.alerts.contains { $0.contains("extension says EXE") }, "\(report.alerts)")
        }

        suite.test("Analyze: a double extension warns when an executable hides behind it") {
            let folder = try Paths.folder("file-double")
            let path = try write(folder, "photo.jpg.exe", portableExecutable())
            let report = try await Examine.inspect(path)
            try expect(report.alerts.contains { $0.contains("JPEG") }, "\(report.alerts)")
            try expect(try value(report, "Extension") == "EXE", "extension")
            try expect(try value(report, "Contents") == "PE", "contents")
        }

        suite.test("Analyze: a mixed-script lookalike is reported and a Cyrillic name is not") {
            let folder = try Paths.folder("file-glyph")
            let mixed = try write(folder, "report\u{0430}.txt", Data("a".utf8))
            let cyrillic = try write(folder, "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}.txt", Data("a".utf8))
            let mixedReport = try await Examine.inspect(mixed)
            let cyrillicReport = try await Examine.inspect(cyrillic)
            try expect(mixedReport.alerts.contains { $0.contains("U+0430") }, "\(mixedReport.alerts)")
            try expect(!cyrillicReport.alerts.contains { $0.contains("lookalike") }, "\(cyrillicReport.alerts)")
        }

        suite.test("Analyze: SHA-256 is computed over the file bytes") {
            let folder = try Paths.folder("file-hash")
            let path = try write(folder, "a.bin", Data("a".utf8))
            let hash = try Checksum.sha256(path)
            try expect(hash == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb", hash)
        }

        suite.test("Analyze: a saved report includes the hash in every format") {
            let folder = try Paths.folder("file-report")
            let path = try write(folder, "note.txt", Data("hello".utf8))
            let report = try await Examine.inspect(path)
            let hash = try Checksum.sha256(path)
            for format in [ReportFormat.csv, .json, .html, .txt] {
                let output = Paths.join(folder, "report." + ReportWriter.fileExtension(format))
                try ReportFile.write(report, sha256: hash, to: output, format: format)
                let text = try String(contentsOfFile: output, encoding: .utf8)
                try expect(text.contains(hash), "\(format) lacks the hash")
            }
        }

        suite.test("Analyze: the task builds the same report") {
            Harness.useSettings()
            let folder = try Paths.folder("file-task")
            let path = try write(folder, "note.txt", Data("hello".utf8))
            let ui = ScriptedInteraction()
            try await Harness.run("file.analyze", [path], ui: ui)
            let extensionRow = ui.fileReport?.overview.first { $0.label == "Extension" }?.value
            try expect(extensionRow == "TXT", "\(String(describing: extensionRow))")
        }

        suite.test("Analyze is offered first for one file of any type, and not for folders or several files") {
            func ids(_ items: [Selection.Item]) -> [String] {
                MenuBuilder.build(Selection.classify(items, probeGifs: false), settings: Settings()).map(\.id)
            }
            let image = ids([Selection.Item(path: "/x/a.png", isDirectory: false, size: 10)])
            try expect(image.first == "file.analyze" && image.contains("image.resize"), "\(image)")
            let unknown = ids([Selection.Item(path: "/x/notes.xyz", isDirectory: false, size: 10)])
            try expect(unknown == ["file.analyze"], "\(unknown)")
            let bare = ids([Selection.Item(path: "/x/README", isDirectory: false, size: 10)])
            try expect(bare == ["file.analyze"], "\(bare)")
            let folder = ids([Selection.Item(path: "/x/Photos", isDirectory: true)])
            try expect(!folder.contains("file.analyze") && folder.contains("folder.analyze"), "\(folder)")
            let two = ids([Selection.Item(path: "/x/a.png", isDirectory: false, size: 10),
                           Selection.Item(path: "/x/b.png", isDirectory: false, size: 10)])
            try expect(!two.contains("file.analyze"), "\(two)")
            var settings = Settings()
            settings.general.hiddenMenuItems = ["file.analyze"]
            let hidden = MenuBuilder.build(Selection.classify([Selection.Item(path: "/x/notes.xyz", isDirectory: false)],
                                                              probeGifs: false), settings: settings)
            try expect(hidden.isEmpty, "\(hidden.map(\.id))")
        }

        suite.test("Analyze survives truncated and corrupted files of every kind") {
            let folder = try Paths.folder("file-fuzz")
            var sources: [(String, Data)] = []
            for name in ["photo.jpg", "alpha.png", "animated.gif", "alpha.pdf", "clip.mp4", "tone.wav", "tone.mp3", "vector.svg"] {
                let copy = try await Fixtures.copy(name, to: folder)
                sources.append((name, try Data(contentsOf: URL(fileURLWithPath: copy))))
            }
            let zip = Paths.join(folder, "pack.zip")
            try await ProcessRunner.runOrThrow("/usr/bin/ditto", ["-c", "-k", Paths.join(folder, "photo.jpg"), zip])
            sources.append(("pack.zip", try Data(contentsOf: URL(fileURLWithPath: zip))))
            sources.append(("pack.jar", try Data(contentsOf: URL(fileURLWithPath: zip))))
            sources.append(("tool.exe", portableExecutable()))
            sources.append(("link.lnk", Data([0x4C, 0, 0, 0, 0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46])
                                          + Data(repeating: 0xFF, count: 120)))
            sources.append(("data.json", Data(#"{"a":[1,2,{"b":"c"}]}"#.utf8)))

            var generator = SystemRandomNumberGenerator()
            for (name, data) in sources {
                var variants: [Data] = [Data()]
                for fraction in [0.02, 0.1, 0.33, 0.5, 0.9] { variants.append(data.prefix(Int(Double(data.count) * fraction))) }
                for _ in 0..<6 {
                    var noisy = data
                    for _ in 0..<max(1, data.count / 50) where !noisy.isEmpty {
                        noisy[Int.random(in: 0..<noisy.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                    }
                    variants.append(noisy)
                }
                for (index, variant) in variants.enumerated() {
                    let path = try write(folder, "\(index)-\(name)", variant)
                    _ = try await Examine.inspect(path)
                }
            }
        }

        suite.test("Analyze suggests the same actions as the menu") {
            Harness.useSettings()
            let folder = try Paths.folder("file-suggest")
            let csv = try write(folder, "people.csv", Data("a,b\n1,2\n".utf8))
            let suggest = Suggest(path: csv, settings: Settings.current)
            let convert = suggest.link("dialog.fileAnalyze.contents")
            try expect(convert?.commands.map(\.verb) == MenuBuilder.textTargets(from: "CSV").map { "text.convert?to=\($0)" },
                       "\(String(describing: convert))")
            try expect(suggest.link("dialog.fileAnalyze.encoding")?.commands.count == 4, "encoding choices")
            try expect(suggest.link("dialog.fileAnalyze.duration") == nil, "no trim for text")
            let audio = try write(folder, "memo.wav", Data())
            let trim = Suggest(path: audio, settings: Settings.current).link("dialog.fileAnalyze.duration")
            try expect(trim?.direct == true && trim?.commands.first?.verb == "audio.trim", "\(String(describing: trim))")
        }
    }
}
