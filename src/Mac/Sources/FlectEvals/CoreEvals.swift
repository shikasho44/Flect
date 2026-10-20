import Foundation
import FlectCore
import FlectKit

enum CoreEvals {
    static func ids(_ nodes: [MenuNode]) -> [String] {
        nodes.flatMap { [$0.id] + ids($0.children) }
    }

    static func item(_ path: String, directory: Bool = false, size: UInt64? = nil) -> Selection.Item {
        Selection.Item(path: path, isDirectory: directory, size: size)
    }

    static func register(_ suite: Suite) {
        suite.test("Menu offers image conversions except the source format") {
            let selection = Selection.classify([item("/x/a.png", size: 2_000_000), item("/x/b.PNG", size: 100)], probeGifs: false)
            let nodes = MenuBuilder.build(selection, settings: Settings())
            let all = ids(nodes)
            try expect(selection.category == .image && selection.formats == ["PNG"], "\(selection.category) \(selection.formats)")
            try expect(!all.contains("image.convert.PNG") && all.contains("image.convert.WEBP"), "\(all)")
            try expect(all.contains("image.compress.p4") && !all.contains("image.compress.p1"), "compress presets should depend on size: \(all)")
        }

        suite.test("Menu hides entries the user unticked") {
            var settings = Settings()
            settings.general.hiddenMenuItems = ["image.ocr", "image.rotate"]
            let nodes = MenuBuilder.build(Selection.classify([item("/x/a.jpg", size: 10)], probeGifs: false), settings: settings)
            let all = ids(nodes)
            try expect(!all.contains("image.ocr") && !all.contains("image.rotate") && !all.contains("image.rotate.p1"), "\(all)")
        }

        suite.test("Menu refuses mixed selections") {
            let selection = Selection.classify([item("/x/a.jpg"), item("/x/b.mp4")], probeGifs: false)
            try expect(selection.isEmpty && MenuBuilder.build(selection, settings: Settings()).isEmpty, "mixed selection")
        }

        suite.test("Menu shows trim only for one video and Discord only for big files") {
            let one = Selection.classify([item("/x/a.mp4", size: 30 * 1024 * 1024)], probeGifs: false)
            let all = ids(MenuBuilder.build(one, settings: Settings()))
            try expect(all.contains("video.trim") && all.contains("video.compress.discord"), "\(all)")
            let two = Selection.classify([item("/x/a.mp4", size: 1024), item("/x/b.mov", size: 1024)], probeGifs: false)
            let many = ids(MenuBuilder.build(two, settings: Settings()))
            try expect(!many.contains("video.trim") && !many.contains("video.compress.discord"), "\(many)")
        }

        suite.test("Menu sorts out folders, packages, archives and text") {
            let folder = Selection.classify([item("/x/Photos", directory: true)], probeGifs: false)
            try expect(folder.category == .folder, "folder")
            let package = Selection.classify([item("/x/Tool.app", directory: true)], probeGifs: false)
            try expect(package.isEmpty, "packages must not count as folders")
            let archive = Selection.classify([item("/x/a.tar.gz"), item("/x/b.rar")], probeGifs: false)
            try expect(archive.category == .archive, "archive")
            let csv = MenuBuilder.build(Selection.classify([item("/x/a.csv")], probeGifs: false), settings: Settings())
            try expect(ids(csv).contains("text.convert.MD") && !ids(csv).contains("json.pretty"), "\(ids(csv))")
            let json = MenuBuilder.build(Selection.classify([item("/x/a.json")], probeGifs: false), settings: Settings())
            try expect(ids(json).contains("json.sort") && ids(json).contains("text.convert.CSV"), "\(ids(json))")
        }

        suite.test("Menu labels follow the language") {
            Loc.use(.japanese)
            defer { Loc.use(.english) }
            let nodes = MenuBuilder.build(Selection.classify([item("/x/a")], probeGifs: false), settings: Settings())
            try expect(nodes.isEmpty, "files without an extension get no menu")
            let folder = MenuBuilder.build(Selection.classify([item("/x/a", directory: true)], probeGifs: false), settings: Settings())
            try expect(folder.first?.label == "重複を削除", folder.first?.label ?? "-")
        }

        suite.test("Every menu entry has a task and a settings label") {
            for entry in MenuCatalog.flatten() where entry.children.isEmpty {
                let parts = entry.id.split(separator: ".")
                let verb = parts.count > 2 ? "\(parts[0]).\(parts[1])" : entry.id
                let request = Request(verb: verb, paths: ["/tmp/x"])!
                try expect(Factory.create(request) != nil, "no task for \(entry.id)")
                try expect(!entry.displayName.hasPrefix("menu."), "no label for \(entry.id)")
            }
        }

        suite.test("Animated GIFs are detected without decoding") {
            let folder = try Paths.folder("core-gif")
            let animated = try await Fixtures.copy("animated.gif", to: folder)
            try expect(GifProbe.isAnimated(animated), "animated gif")
            let still = Paths.join(folder, "still.gif")
            try Fixtures.save(Fixtures.canvas(10, 10) { _ in }, still, type: "com.compuserve.gif")
            try expect(!GifProbe.isAnimated(still), "still gif")
        }

        suite.test("Handoff URLs survive special characters") {
            let paths = ["/Users/me/写真 & memo/100%.png", "/tmp/a+b=c?.jpg"]
            guard let url = Handoff.url(verb: "image.convert?to=PNG", paths: paths, token: "abc") else {
                throw EvalFailure(description: "no url")
            }
            guard let parsed = Handoff.parse(url) else { throw EvalFailure(description: "parse failed for \(url)") }
            try expect(parsed.verb == "image.convert?to=PNG" && parsed.paths == paths && parsed.token == "abc", "\(parsed)")
        }

        suite.test("Requests read parameters case-insensitively") {
            let request = Request(verb: "video.compress?Bytes=123&preset=discord", paths: ["/a"])!
            try expect(request.id == "video.compress" && request["bytes"] == "123" && request["PRESET"] == "discord", "\(request)")
            try expect(Request(verb: "nodot", paths: ["/a"]) == nil, "verb without a domain")
        }

        suite.test("Formatting matches the Windows app") {
            try expect(Formatting.bytes(1536) == "1.50 KB" && Formatting.bytes(20 * 1024 * 1024) == "20.0 MB", Formatting.bytes(1536))
            try expect(Formatting.shortBytes(20 * 1024 * 1024) == "20 MB" && Formatting.shortBytes(1_572_864) == "1.5 MB",
                       Formatting.shortBytes(1_572_864))
            try expect(Formatting.parseBytes("8MB") == 8_388_608 && Formatting.parseBytes("900 kb") == 921_600, "parse")
            try expect(Formatting.parseTimecode("1:02:03.5") == 3723.5 && Formatting.parseTimecode("x") == nil, "timecode")
            try expect(Formatting.timecode(65.43) == "1:05.4" && Formatting.timecode(3723.5) == "1:02:03.5", Formatting.timecode(65.43))
        }

        suite.test("Settings round trip and corrupt files are set aside") {
            Harness.useSettings { $0.video.gifFps = 24 }
            try expect(Settings.reload().video.gifFps == 24, "round trip")
            let file = Store.directory.appendingPathComponent(Settings.fileName)
            try Data("{ not json".utf8).write(to: file)
            try expect(Settings.reload() == Settings(), "corrupt settings should fall back to defaults")
            try expect(FileManager.default.fileExists(atPath: file.path + ".broken"), "broken file not kept")
        }

        suite.test("Settings written by the Windows app are understood") {
            let windows = """
            {"Version":1,"General":{"Theme":"Dark","Language":"Japanese","HiddenMenuItems":["image.ocr"]},
             "Video":{"Codec":"Vp9","Hardware":"Nvenc","Presets":{"CompressDiscord":10485760}},
             "Folder":{"DeleteMethod":"Permanent","Duplicates":{"Keep":"Newest"}},
             "Ocr":{"Encoding":"ShiftJis"},"Unknown":{"X":1}}
            """
            let settings = try Store.decodeLeniently(Settings.self, from: Data(windows.utf8), defaults: Settings())
            try expect(settings.general.theme == .dark && settings.general.language == .japanese, "general")
            try expect(settings.general.hiddenMenuItems == ["image.ocr"] && settings.video.codec == .vp9, "lists and enums")
            try expect(settings.folder.deleteMethod == .permanent && settings.folder.duplicates.keep == .newest, "folder")
            try expect(settings.ocr.encoding == .shiftJis && settings.image.webpQuality == 80, "defaults fill the gaps")
        }

        suite.test("The legacy Discord preset is raised") {
            Settings.reset()
            let legacy = "{\"Version\":0,\"Video\":{\"Presets\":{\"CompressDiscord\":10485760}}}"
            try FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
            try Data(legacy.utf8).write(to: Store.directory.appendingPathComponent(Settings.fileName))
            let settings = Settings.reload()
            try expect(settings.video.presets.compressDiscord == VideoPresets.discordLimit, "\(settings.video.presets.compressDiscord)")
        }

        suite.test("Every string exists in all three languages") {
            var missing: [String] = []
            for language in [AppLanguage.japanese, .chineseSimplified] {
                Loc.use(language)
                for entry in MenuCatalog.flatten() where !entry.labelKey.hasPrefix("menu.to") {
                    if Loc.t(entry.labelKey) == entry.labelKey { missing.append("\(language.rawValue):\(entry.labelKey)") }
                }
            }
            Loc.use(.english)
            missing += Strings.missingTranslations()
            try expect(missing.isEmpty, "\(missing)")
        }

        for (input, expected) in [("1.0.0", [1, 0, 0, 0]), ("flect-1.0", [1, 0, 0, 0]), ("v1.0.1", [1, 0, 1, 0]),
                                  ("Flect 2.5", [2, 5, 0, 0]), ("3.14.15.92", [3, 14, 15, 92])] {
            suite.test("Update parses \(input)") {
                try expect(Updater.version(input) == expected, "\(Updater.version(input) ?? [])")
            }
        }

        suite.test("Update ignores invalid versions and Windows-only releases") {
            try expect(Updater.version("none") == nil && Updater.version("") == nil && Updater.version(nil) == nil, "invalid")
            let releases: [[String: Any]] = [
                ["tag_name": "flect-9.0", "html_url": "https://example.com/9", "assets": [["name": "Flect-Setup.exe"]]],
                ["tag_name": "flect-1.2", "html_url": "https://example.com/12",
                 "assets": [["name": "Flect-1.2-mac.dmg", "browser_download_url": "https://example.com/12.dmg"]]],
                ["tag_name": "flect-1.3", "draft": true, "html_url": "https://example.com/13",
                 "assets": [["name": "Flect-1.3-mac.dmg"]]],
            ]
            let found = Updater.newest(releases, than: "1.0.1")
            try expect(found?.version == "1.2" && found?.download?.absoluteString == "https://example.com/12.dmg", "\(String(describing: found))")
            try expect(Updater.newest(releases, than: "1.2") == nil, "same version is not an update")
        }
    }
}
