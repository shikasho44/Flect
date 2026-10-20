import Foundation
import FlectCore
import FlectKit

enum FolderEvals {
    static func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func register(_ suite: Suite) {
        suite.test("Remove duplicate keeps the oldest copy") {
            Harness.useSettings { settings in
                settings.folder.duplicates.keep = .oldest
                settings.folder.deleteMethod = .permanent
            }
            let folder = try Paths.folder("folder-dups")
            let original = Paths.join(folder, "a.txt")
            try write(original, String(repeating: "x", count: 4096))
            try write(Paths.join(folder, "b.txt"), String(repeating: "x", count: 4096))
            try write(Paths.join(folder, "sub/d.txt"), String(repeating: "x", count: 4096))
            try write(Paths.join(folder, "c.txt"), String(repeating: "y", count: 4096))
            try write(Paths.join(folder, "sub/.DS_Store"), "finder")
            try write(Paths.join(folder, ".DS_Store"), "finder")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-864_000)], ofItemAtPath: original)

            let (_, task) = try await Harness.run("folder.removeDuplicate", [folder])
            try expect(Paths.exists(original) && Paths.exists(Paths.join(folder, "c.txt")), "kept files missing")
            try expect(!Paths.exists(Paths.join(folder, "b.txt")) && !Paths.exists(Paths.join(folder, "sub/d.txt")), "duplicates remain")
            try expect(Paths.exists(Paths.join(folder, ".DS_Store")) && Paths.exists(Paths.join(folder, "sub/.DS_Store")),
                       ".DS_Store files must never be treated as duplicates")
            try expect(task.summary?.contains("2") == true, "summary \(task.summary ?? "-")")
        }

        suite.test("Remove duplicate asks which copy to keep") {
            Harness.useSettings { $0.folder.deleteMethod = .permanent }
            let folder = try Paths.folder("folder-dups-ask")
            try write(Paths.join(folder, "one.bin"), String(repeating: "z", count: 70_000))
            try write(Paths.join(folder, "two.bin"), String(repeating: "z", count: 70_000))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100)],
                                                  ofItemAtPath: Paths.join(folder, "one.bin"))
            let ui = ScriptedInteraction()
            ui.duplicates = .keepNewest
            try await Harness.run("folder.removeDuplicate", [folder], ui: ui)
            try expect(Paths.listing(folder) == ["two.bin"], "\(Paths.listing(folder))")
        }

        suite.test("Remove duplicate never descends into packages") {
            Harness.useSettings { settings in
                settings.folder.duplicates.keep = .oldest
                settings.folder.deleteMethod = .permanent
            }
            let folder = try Paths.folder("folder-dups-package")
            try write(Paths.join(folder, "Tool.app/Contents/Info.plist"), "same")
            try write(Paths.join(folder, "copy.plist"), "same")
            try await Harness.run("folder.removeDuplicate", [folder])
            try expect(Paths.exists(Paths.join(folder, "Tool.app/Contents/Info.plist")) && Paths.exists(Paths.join(folder, "copy.plist")),
                       "files inside packages must stay")
        }

        suite.test("Empty folder scan finds only the outermost empty folders") {
            Harness.useSettings { $0.folder.deleteMethod = .permanent }
            let folder = try Paths.folder("folder-empty")
            try FileManager.default.createDirectory(atPath: Paths.join(folder, "empty/nested"), withIntermediateDirectories: true)
            try write(Paths.join(folder, "kept/file.txt"), "x")
            try write(Paths.join(folder, "ini-only/desktop.ini"), "[.ShellClassInfo]")
            try write(Paths.join(folder, "finder-only/.DS_Store"), "finder")
            let ui = ScriptedInteraction()
            try await Harness.run("folder.removeEmpty", [folder], ui: ui)
            try expect(Paths.listing(folder) == ["kept"], "\(Paths.listing(folder))")
        }

        suite.test("Remove empty keeps folders that only hold excluded folders or links") {
            Harness.useSettings { settings in
                settings.folder.deleteMethod = .permanent
                settings.folder.scanExclusions.folders = "Backup"
            }
            let folder = try Paths.folder("folder-empty-excluded")
            try write(Paths.join(folder, "old/Backup/keep.txt"), "keep")
            try FileManager.default.createDirectory(atPath: Paths.join(folder, "linked"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: Paths.join(folder, "linked/link"), withDestinationPath: "/tmp")
            let (_, task) = try await Harness.run("folder.removeEmpty", [folder])
            try expect(Paths.exists(Paths.join(folder, "old/Backup/keep.txt")) && Paths.exists(Paths.join(folder, "linked")),
                       "summary \(task.summary ?? "-")")
        }

        suite.test("Remove empty asks before deleting") {
            Harness.useSettings { $0.folder.deleteMethod = .permanent }
            let folder = try Paths.folder("folder-empty-declined")
            try FileManager.default.createDirectory(atPath: Paths.join(folder, "empty"), withIntermediateDirectories: true)
            let ui = ScriptedInteraction()
            ui.confirmation = false
            do {
                try await Harness.run("folder.removeEmpty", [folder], ui: ui)
                throw EvalFailure(description: "declining should cancel the task")
            } catch is CancellationError {
            }
            try expect(Paths.exists(Paths.join(folder, "empty")), "declined deletion still happened")
        }

        suite.test("Tree prints the folder structure") {
            Harness.useSettings()
            let folder = try Paths.folder("folder-tree")
            try write(Paths.join(folder, "b/inner.txt"), "x")
            try write(Paths.join(folder, "a.txt"), "x")
            try write(Paths.join(folder, ".DS_Store"), "x")
            let ui = ScriptedInteraction()
            try await Harness.run("folder.tree", [folder], ui: ui)
            let expected = """
            \(folder)
            ├───b
            │   └───inner.txt
            └───a.txt

            """
            try expect(ui.shownText == expected, "got:\n\(ui.shownText ?? "-")")
        }

        suite.test("Rename numbers files in Finder order") {
            Harness.useSettings()
            let folder = try Paths.folder("folder-rename")
            for name in ["shot10.png", "shot2.png", "shot1.png", "notes.txt"] { try write(Paths.join(folder, name), name) }
            let ui = ScriptedInteraction()
            ui.rename = RenamePlan(prefix: "trip_", name: "", suffix: "", numbered: true)
            let (_, task) = try await Harness.run("folder.rename", [folder], ui: ui)
            try expect(Paths.listing(folder) == ["trip_1.png", "trip_1.txt", "trip_2.png", "trip_3.png"], "\(Paths.listing(folder))")
            try expect(try String(contentsOfFile: Paths.join(folder, "trip_3.png"), encoding: .utf8) == "shot10.png", "order")
            try expect(task.summary?.contains("4") == true, "summary \(task.summary ?? "-")")
        }

        suite.test("Rename dry run changes nothing") {
            Harness.useSettings { $0.folder.rename.dryRun = true }
            let folder = try Paths.folder("folder-rename-dry")
            try write(Paths.join(folder, "a.png"), "a")
            let ui = ScriptedInteraction()
            ui.rename = RenamePlan(prefix: "x_", name: "", suffix: "", numbered: true)
            try await Harness.run("folder.rename", [folder], ui: ui)
            try expect(Paths.listing(folder) == ["a.png"], "\(Paths.listing(folder))")
            try expect(ui.shownText?.contains("a.png  ->  x_1.png") == true, ui.shownText ?? "-")
        }

        suite.test("Analyze builds a report in every format") {
            Harness.useSettings()
            let folder = try Paths.folder("folder-analyze")
            try write(Paths.join(folder, "big.bin"), String(repeating: "b", count: 50_000))
            try write(Paths.join(folder, "copy/big.bin"), String(repeating: "b", count: 50_000))
            try write(Paths.join(folder, "note.txt"), "hello")
            try FileManager.default.createDirectory(atPath: Paths.join(folder, "void"), withIntermediateDirectories: true)
            let ui = ScriptedInteraction()
            try await Harness.run("folder.analyze", [folder], ui: ui)
            guard let report = ui.analyzed else { throw EvalFailure(description: "no report") }
            try expect(report.fileCount == 3 && report.duplicateGroups == 1 && report.emptyDirectories.count == 1,
                       "files \(report.fileCount) dups \(report.duplicateGroups) empty \(report.emptyDirectories.count)")
            let reports = try Paths.folder("folder-analyze-reports")
            for format in ReportFormat.allCases {
                let path = Paths.join(reports, "report.\(ReportWriter.fileExtension(format))")
                try ReportWriter.write(report, to: path, format: format)
                try expect(Paths.size(path) > 50, "\(format) report is empty")
            }
            let json = try String(contentsOfFile: Paths.join(reports, "report.json"), encoding: .utf8)
            _ = try JSONParser.parse(json)
        }

        for (format, name) in [(ArchiveCompressFormat.zip, "My Folder.zip"), (.sevenZip, "My Folder.7z"),
                               (.tar, "My Folder.tar"), (.tarGz, "My Folder.tar.gz")] {
            suite.test("Compressed folders extract back to the same files (\(format.rawValue))") {
                Harness.useSettings { $0.folder.archive.compressFormat = format }
                let root = try Paths.folder("folder-archive-\(format.rawValue)")
                let source = Paths.join(root, "My Folder")
                try write(Paths.join(source, "日本語のファイル.txt"), "こんにちは")
                try write(Paths.join(source, "nested/deep.txt"), String(repeating: "d", count: 10_000))
                try write(Paths.join(source, ".DS_Store"), "finder")

                try await Harness.run("folder.compress", [source])
                let archive = Paths.join(root, name)
                try expect(Paths.exists(archive), "archive missing: \(Paths.listing(root))")
                try expect(Paths.listing(root).allSatisfy { !$0.hasPrefix(".Flect-") }, "scratch left behind")

                let unpack = try Paths.folder("folder-archive-\(format.rawValue)-out")
                let copied = Paths.join(unpack, name)
                try FileManager.default.copyItem(atPath: archive, toPath: copied)
                try await Harness.run("archive.extract", [copied])
                let extracted = Paths.join(unpack, "My Folder/My Folder")
                try expect(try String(contentsOfFile: Paths.join(extracted, "日本語のファイル.txt"), encoding: .utf8) == "こんにちは",
                           "contents \(Paths.listing(Paths.join(unpack, "My Folder")))")
                try expect(Paths.size(Paths.join(extracted, "nested/deep.txt")) == 10_000, "nested file")
                try expect(!Paths.exists(Paths.join(extracted, ".DS_Store")), ".DS_Store should be left out")
            }
        }

        suite.test("Zip archives from Windows keep their Japanese names") {
            Harness.useSettings()
            let folder = try Paths.folder("folder-legacy-zip")
            let name = "資料.txt"
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding("windows-31j" as CFString)))
            let archive = Paths.join(folder, "legacy.zip")
            try LegacyZip.write(archive, name: name.data(using: encoding)!, contents: Data("中身".utf8))
            try await Harness.run("archive.extract", [archive])
            let extracted = Paths.join(folder, "legacy/\(name)")
            try expect(Paths.exists(extracted), "names \(Paths.listing(Paths.join(folder, "legacy")))")
        }

        suite.test("Cancelling compression leaves nothing behind") {
            Harness.useSettings { $0.folder.archive.compressFormat = .sevenZip }
            let root = try Paths.folder("folder-archive-cancel")
            let source = Paths.join(root, "Big")
            try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<6 {
                let bytes = (0..<8_000_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
                try Data(bytes).write(to: URL(fileURLWithPath: Paths.join(source, "part\(index).bin")))
            }
            let task = Factory.create(Request(verb: "folder.compress", paths: [source])!)!
            _ = await task.configure(ScriptedInteraction())
            let running = Task { try await task.run(RecordingProgress()) }
            try await Task.sleep(nanoseconds: 300_000_000)
            running.cancel()
            _ = try? await running.value
            try await Task.sleep(nanoseconds: 300_000_000)
            try expect(Paths.listing(root) == ["Big"], "\(Paths.listing(root))")
        }

        suite.test("RAR archives extract") {
            Harness.useSettings()
            let folder = try Paths.folder("folder-rar")
            let archive = Paths.join(folder, "sample.rar")
            try LegacyRar.write(archive, name: "hello.txt", contents: Data("hello from rar\n".utf8))
            try await Harness.run("archive.extract", [archive])
            try expect(try String(contentsOfFile: Paths.join(folder, "sample/hello.txt"), encoding: .utf8) == "hello from rar\n",
                       "\(Paths.listing(Paths.join(folder, "sample")))")
        }

        suite.test("RAR extracts a real sample when one is provided") {
            guard let sample = ProcessInfo.processInfo.environment["FLECT_RAR_SAMPLE"], Paths.exists(sample) else {
                throw Skip(reason: "set FLECT_RAR_SAMPLE to a .rar file")
            }
            let folder = try Paths.folder("folder-rar-sample")
            let copied = Paths.join(folder, "sample.rar")
            try FileManager.default.copyItem(atPath: sample, toPath: copied)
            try await Harness.run("archive.extract", [copied])
            try expect(!Paths.listing(Paths.join(folder, "sample")).isEmpty, "nothing extracted")
        }

        suite.test("Moving to the Trash works", category: "trash") {
            let folder = try Paths.folder("folder-trash")
            let file = Paths.join(folder, "flect-evals-trash-test.txt")
            try write(file, "Created by Flect evals. Safe to delete.")
            try Recycler.delete([file], method: .recycleBin)
            try expect(!Paths.exists(file), "file still present")
        }
    }
}

enum LegacyZip {
    static func write(_ path: String, name: Data, contents: Data) throws {
        var crc = CRC32()
        crc.update(contents)
        var local = Data()
        local.appendLE32(0x04034B50)
        local.appendLE16(10)
        local.appendLE16(0)
        local.appendLE16(0)
        local.appendLE16(0)
        local.appendLE16(0)
        local.appendLE32(crc.value)
        local.appendLE32(UInt32(contents.count))
        local.appendLE32(UInt32(contents.count))
        local.appendLE16(UInt16(name.count))
        local.appendLE16(0)
        local.append(name)
        local.append(contents)

        var central = Data()
        central.appendLE32(0x02014B50)
        central.appendLE16(20)
        central.appendLE16(10)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE32(crc.value)
        central.appendLE32(UInt32(contents.count))
        central.appendLE32(UInt32(contents.count))
        central.appendLE16(UInt16(name.count))
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE16(0)
        central.appendLE32(0)
        central.appendLE32(0)
        central.append(name)

        var end = Data()
        end.appendLE32(0x06054B50)
        end.appendLE16(0)
        end.appendLE16(0)
        end.appendLE16(1)
        end.appendLE16(1)
        end.appendLE32(UInt32(central.count))
        end.appendLE32(UInt32(local.count))
        end.appendLE16(0)

        try (local + central + end).write(to: URL(fileURLWithPath: path))
    }
}

enum LegacyRar {
    static func write(_ path: String, name: String, contents: Data) throws {
        var crc = CRC32()
        crc.update(contents)
        let nameBytes = Data(name.utf8)

        var archive = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        archive += block(type: 0x73, flags: 0, body: Data(count: 6))

        var file = Data()
        file.appendLE32(UInt32(contents.count))
        file.appendLE32(UInt32(contents.count))
        file.append(3)
        file.appendLE32(crc.value)
        file.appendLE32(0x5B54_6000)
        file.append(20)
        file.append(0x30)
        file.appendLE16(UInt16(nameBytes.count))
        file.appendLE32(0o100644)
        file.append(nameBytes)
        archive += block(type: 0x74, flags: 0x8000, body: file)
        archive += contents
        archive += block(type: 0x7B, flags: 0x4000, body: Data())
        try archive.write(to: URL(fileURLWithPath: path))
    }

    private static func block(type: UInt8, flags: UInt16, body: Data) -> Data {
        var header = Data([type])
        header.appendLE16(flags)
        header.appendLE16(UInt16(7 + body.count))
        header.append(body)
        var crc = CRC32()
        crc.update(header)
        var block = Data()
        block.appendLE16(UInt16(crc.value & 0xFFFF))
        block.append(header)
        return block
    }
}

struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        for byte in data { state = CRC32.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8) }
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}

extension Data {
    mutating func appendLE16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func appendLE32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
