import AppKit
import Darwin
import FlectCore
import FlectKit

// End-to-end run against an installed Flect.app. Every Finder menu entry is handed to the app through the same
// flect:// link the Finder extension opens, and what appears on disk or on screen is written to results.json.
enum Demo {
    struct Step: Codable {
        var group: String
        var title: String
        var verb: String
        var route: String
        var folder: String
        var inputs: [String]
        var created: [String] = []
        var changed: [String] = []
        var removed: [String] = []
        var windows = 0
        var seconds = 0.0
        var status = ""
        var note = ""
    }

    private struct Entry {
        let size: Int64
        let modified: Date
    }

    private static var app = URL(fileURLWithPath: "/")
    private static var bundleID = ""
    private static var token: String?
    private static var root = ""
    private static var steps: [Step] = []

    // Menu entries that open a window instead of finishing on their own, and the values the window would collect.
    private static let scripted: [String: String] = [
        "image.resize?scale=custom": "image.resize?w=200&h=150",
        "image.compress?bytes=custom": "image.compress?bytes=150000",
        "video.resize?scale=custom": "video.resize?w=320&h=180",
        "video.compress?bytes=custom": "video.compress?bytes=300000",
        "video.trim": "video.trim?start=00:00:01&end=00:00:03",
        "video.thumbnail": "video.thumbnail?time=00:00:02",
        "folder.rename": "folder.rename?prefix=demo_&numbered=1",
        "folder.removeDuplicate": "folder.removeDuplicate?keep=oldest",
        "folder.removeEmpty": "folder.removeEmpty?confirm=yes",
        "pdf.merge": "pdf.merge?order=name",
    ]

    // Menu entries whose job is to open a window: what that window is.
    private static let windows: [String: String] = [
        "image.resize?scale=custom": "サイズを入力する画面",
        "image.compress?bytes=custom": "目標サイズを入力する画面",
        "video.resize?scale=custom": "サイズを入力する画面",
        "video.compress?bytes=custom": "目標サイズを入力する画面",
        "video.trim": "切り出す範囲を選ぶ画面",
        "video.thumbnail": "使う場面を選ぶ画面",
        "folder.rename": "新しい名前の付け方を入力する画面",
        "folder.removeDuplicate": "どれを残すか選ぶ画面",
        "folder.removeEmpty": "削除してよいかの確認",
        "folder.tree": "ツリーを表示する結果画面",
        "folder.analyze": "解析結果の画面",
        "pdf.merge": "結合する順番を決める画面",
        "pdf.preview": "PDF のプレビュー画面",
        "showActions": "操作を選ぶ画面",
        "open": "操作を選ぶ画面",
    ]

    static func run(appPath: String, output: String) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        app = URL(fileURLWithPath: appPath)
        guard let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier else {
            throw EvalFailure(description: "no app at \(appPath)")
        }
        bundleID = identifier
        token = Handoff.readToken()
        root = output
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        Fixtures.masters = (output as NSString).appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(atPath: Fixtures.masters, withIntermediateDirectories: true)
        Paths.root = (output as NSString).appendingPathComponent("cases")

        let settings = Settings.load()
        Loc.use(settings.general.language)
        print("Demo against \(appPath) (\(bundleID)), token \(token == nil ? "missing" : "present")")
        await quitApp()

        try await menu("画像", ["scene.jpg"], settings, skip: ["image.ocr"])
        try await menu("画像（文字入り PNG）", ["ocr.png"], settings, only: ["image.ocr", "image.chromakey"])
        try await menu("アニメーション GIF", ["animated.gif"], settings, skip: ["image.ocr"], unscripted: ["image.compress.custom"])
        try await menu("動画", ["clip.mp4"], settings, skip: ["video.subtitles"])
        try await extra("動画", "圧縮（目標サイズ指定）", "video.compress?bytes=300000", ["clip.mp4"])
        try await extra("動画", "字幕（音声入り動画）", "video.subtitles", ["speech.mp4"])
        try await menu("音声", ["speech.wav"], settings)
        try await menu("PDF（1 つ）", ["alpha.pdf"], settings)
        try await menu("PDF（2 つ）", ["alpha.pdf", "bravo.pdf"], settings, only: ["pdf.merge"])
        try await menu("テキスト（CSV）", ["people.csv"], settings)
        try await menu("テキスト（JSON）", ["data.json"], settings)
        try await menu("テキスト（XML）", ["config.xml"], settings, only: ["text.convert.JSON"])
        try await menu("テキスト（日本語）", ["memo.txt"], settings, only: ["text.encode.SJIS", "text.encode.UTF16"])
        try await menu("フォルダ", ["sample-folder"], settings)
        try await menu("アーカイブ", ["sample.zip"], settings)
        try await other()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(steps).write(to: URL(fileURLWithPath: (output as NSString).appendingPathComponent("results.json")))
        let failed = steps.filter { $0.status == "failed" }
        print("\n\(steps.count) steps, \(failed.count) failed")
    }

    // MARK: Cases

    private static func menu(_ group: String, _ inputs: [String], _ settings: Settings,
                             only: Set<String>? = nil, skip: Set<String> = [], unscripted: Set<String> = []) async throws {
        let sample = try await prepare("menu-probe", inputs)
        let urls = sample.map { URL(fileURLWithPath: $0) }
        let nodes = MenuBuilder.build(Selection.classify(urls, inspect: true), settings: settings)
        for (path, leaf) in leaves(nodes, []) {
            if let only, !only.contains(leaf.id) { continue }
            if skip.contains(leaf.id) { continue }
            guard let verb = leaf.verb else { continue }
            let title = (path + [leaf.label]).joined(separator: " › ")
            try await step(group, title, verb, inputs, route: "menu")
            if let answer = scripted[verb], !unscripted.contains(leaf.id) {
                try await step(group, title + "（画面で入力する値を指定）", answer, inputs, route: "scripted")
            }
        }
    }

    private static func extra(_ group: String, _ title: String, _ verb: String, _ inputs: [String]) async throws {
        try await step(group, title, verb, inputs, route: "scripted")
    }

    private static func other() async throws {
        // Services menu: what right-click › Services › Process with Flect… and ⇧⌘J send.
        var item = Step(group: "右クリックの代わり", title: "サービス「Flect で処理…」", verb: "showActions", route: "service",
                        folder: "", inputs: ["photo.jpg"])
        let paths = try await prepare("service", ["photo.jpg"])
        item.folder = (paths[0] as NSString).deletingLastPathComponent
        let board = NSPasteboard(name: NSPasteboard.Name("FlectDemo"))
        board.clearContents()
        board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        let started = Date()
        let performed = NSPerformService("Process with Flect…", board)
        item = await settle(item, started: started, before: snapshot(item.folder))
        item.status = performed && item.windows > 0 ? "window" : "failed"
        item.note = performed ? "操作を選ぶ画面が開いた" : "サービスが見つからない"
        record(item)

        // Dropping files on the Dock icon opens the app with those files.
        var drop = Step(group: "右クリックの代わり", title: "Dock のアイコンにドロップ", verb: "open", route: "drop",
                        folder: "", inputs: ["clip.mp4"])
        let dropped = try await prepare("drop", ["clip.mp4"])
        drop.folder = (dropped[0] as NSString).deletingLastPathComponent
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let dropStart = Date()
        _ = try? await NSWorkspace.shared.open(dropped.map { URL(fileURLWithPath: $0) }, withApplicationAt: app,
                                               configuration: configuration)
        drop = await settle(drop, started: dropStart, before: snapshot(drop.folder))
        drop.status = drop.windows > 0 ? "window" : "failed"
        drop.note = "操作を選ぶ画面が開いた"
        record(drop)
    }

    private static func step(_ group: String, _ title: String, _ verb: String, _ inputs: [String], route: String) async throws {
        let slug = String(format: "%03d-", steps.count + 1)
            + verb.replacingOccurrences(of: "?", with: "-").replacingOccurrences(of: "&", with: "-")
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: ":", with: "")
        let paths = try await prepare(slug, inputs)
        var item = Step(group: group, title: title, verb: verb, route: route,
                        folder: (paths[0] as NSString).deletingLastPathComponent, inputs: inputs)
        let before = snapshot(item.folder)
        guard let url = Handoff.url(verb: verb, paths: paths, token: token) else {
            item.status = "failed"
            item.note = "link could not be built"
            record(item)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let started = Date()
        _ = try? await NSWorkspace.shared.open(url, configuration: configuration)
        item = await settle(item, started: started, before: before)

        let touched = !(item.created.isEmpty && item.changed.isEmpty && item.removed.isEmpty)
        let expected = windows[verb] ?? windows[verb.split(separator: "?").first.map(String.init) ?? verb]
        switch (touched, item.windows > 0) {
        case (true, false): item.status = "ok"
        case (true, true): item.status = "ok"; item.note = "結果の画面も開いた"
        case (false, true) where expected != nil: item.status = "window"; item.note = expected!
        case (false, true): item.status = "failed"; item.note = "ファイルができず、画面が開いた（エラー表示）"
        case (false, false): item.status = "failed"; item.note = "何も起きなかった"
        }
        record(item)
    }

    private static func record(_ item: Step) {
        steps.append(item)
        let mark = item.status == "failed" ? "FAIL" : item.status == "window" ? "WIN " : "OK  "
        print(String(format: "%@ %5.1fs  %@ / %@  [%@] %@", mark, item.seconds, item.group, item.title,
                     (item.created + item.changed).joined(separator: ", "), item.note))
    }

    // MARK: Waiting for the app

    private static func settle(_ step: Step, started: Date, before: [String: Entry]) async -> Step {
        var item = step
        var last = before
        var stableSince = Date()
        var seenApp = false
        let deadline = Date().addingTimeInterval(240)

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let now = snapshot(item.folder)
            if !same(now, last) {
                last = now
                stableSince = Date()
            }
            if let pid = appProcesses().first {
                seenApp = true
                // Still open, nothing changing on disk: a dialog or a result window is waiting for a person.
                let windows = windowCount(pid)
                if windows > 0, Date().timeIntervalSince(stableSince) > 5, !hasScratch(item.folder) {
                    item.windows = windows
                    if !same(now, before) || expectsWindow(item.verb) { break }
                    capture(pid, into: item.folder)
                    break
                }
            } else if seenApp || Date().timeIntervalSince(started) > 15
                        || (!same(now, before) && Date().timeIntervalSince(stableSince) > 2) {
                break
            }
        }
        item.seconds = Date().timeIntervalSince(started)

        let after = snapshot(item.folder)
        item.created = after.keys.filter { before[$0] == nil }.sorted()
        item.removed = before.keys.filter { after[$0] == nil }.sorted()
        item.changed = after.keys.filter { key in
            guard let old = before[key], let new = after[key] else { return false }
            return old.size != new.size || old.modified != new.modified
        }.sorted()
        await quitApp()
        return item
    }

    // NSRunningApplication only refreshes on a run loop this command line tool does not spin, so ask the kernel.
    private static func appProcesses() -> [pid_t] {
        let executable = app.appendingPathComponent("Contents/MacOS/Flect").resolvingSymlinksInPath().path
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4096)
        return pids.prefix(max(count, 0)).filter { pid in
            pid > 0 && proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == executable
        }
    }

    private static func quitApp() async {
        for pid in appProcesses() {
            kill(pid, SIGTERM)
            for _ in 0..<10 where kill(pid, 0) == 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func expectsWindow(_ verb: String) -> Bool {
        windows[verb] != nil || windows[verb.split(separator: "?").first.map(String.init) ?? verb] != nil
    }

    // Keeps a picture of an unexpected window (usually an error message) next to the case.
    private static func capture(_ pid: pid_t, into folder: String) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let window = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }),
              let id = window[kCGWindowNumber as String] as? Int else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(id), (folder as NSString).appendingPathComponent("window.png")]
        try? task.run()
        task.waitUntilExit()
    }

    private static func windowCount(_ pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 99) < 20
        }.count
    }

    private static func snapshot(_ folder: String) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return entries }
        while let name = walker.nextObject() as? String {
            if name.hasPrefix(".\(Branding.name)-") || name.contains("/.\(Branding.name)-") { continue }
            let path = (folder as NSString).appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let directory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            entries[name + (directory ? "/" : "")] = Entry(size: directory ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                                                          modified: attributes[.modificationDate] as? Date ?? .distantPast)
        }
        return entries
    }

    private static func hasScratch(_ folder: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { $0.hasPrefix(".\(Branding.name)-") }
    }

    private static func same(_ a: [String: Entry], _ b: [String: Entry]) -> Bool {
        a.count == b.count && a.allSatisfy { key, value in
            b[key].map { $0.size == value.size && $0.modified == value.modified } ?? false
        }
    }

    private static func leaves(_ nodes: [MenuNode], _ path: [String]) -> [([String], MenuNode)] {
        nodes.flatMap { node in
            node.children.isEmpty ? [(path, node)] : leaves(node.children, path + [node.label])
        }
    }

    // MARK: Fixtures

    private static func prepare(_ name: String, _ inputs: [String]) async throws -> [String] {
        let folder = try Paths.folder(name)
        var paths: [String] = []
        for input in inputs {
            switch input {
            case "people.csv":
                paths.append(try write(folder, input, "name,age,city\nAlice,30,Tokyo\nBob,25,Osaka\n佐藤,41,札幌\n"))
            case "data.json":
                paths.append(try write(folder, input,
                    #"[{"name":"Alice","age":30,"tags":{"b":2,"a":1}},{"name":"佐藤","age":41,"city":"札幌"}]"#))
            case "config.xml":
                paths.append(try write(folder, input, "<config><name>Flect</name><size>3</size></config>\n"))
            case "memo.txt":
                paths.append(try write(folder, input, "フレクトのテストです。\r\n二行目です。\r\n"))
            case "scene.jpg":
                let master = Paths.join(Fixtures.masters, input)
                if !Paths.exists(master) {
                    let raw = master + ".raw.jpg"
                    try await ProcessRunner.runOrThrow(try Tools.ffmpeg(), [
                        "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                        "-i", "mandelbrot=s=1920x1280:maxiter=400:start_scale=1.2:end_pts=1", "-frames:v", "1", "-q:v", "2", raw])
                    try Fixtures.save(try Inspect.image(raw), master, type: "public.jpeg", properties: [
                        kCGImageDestinationLossyCompressionQuality as String: 0.92,
                        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "FlectCam"],
                        kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:10:20 12:00:00"],
                        kCGImagePropertyGPSDictionary as String: [
                            kCGImagePropertyGPSLatitude as String: 35.6833, kCGImagePropertyGPSLatitudeRef as String: "N",
                            kCGImagePropertyGPSLongitude as String: 139.7667, kCGImagePropertyGPSLongitudeRef as String: "E",
                        ],
                    ])
                    try FileManager.default.removeItem(atPath: raw)
                }
                let target = Paths.join(folder, input)
                try FileManager.default.copyItem(atPath: master, toPath: target)
                paths.append(target)
            case "speech.mp4":
                let audio = try await Fixtures.copy("speech.wav", to: folder)
                let video = Paths.join(folder, input)
                try await ProcessRunner.runOrThrow(try Tools.ffmpeg(), [
                    "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x223355:s=640x360:r=30",
                    "-i", audio, "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video])
                try FileManager.default.removeItem(atPath: audio)
                paths.append(video)
            case "sample-folder":
                let base = Paths.join(folder, input)
                try FileManager.default.createDirectory(atPath: Paths.join(base, "empty/inner"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: Paths.join(base, "photos"), withIntermediateDirectories: true)
                _ = try await Fixtures.copy("photo.jpg", to: Paths.join(base, "photos"), as: "a.jpg")
                _ = try await Fixtures.copy("photo.jpg", to: Paths.join(base, "photos"), as: "a-copy.jpg")
                _ = try await Fixtures.copy("ocr.png", to: base, as: "scan.png")
                _ = try write(base, "notes.txt", "Flect demo folder\n")
                paths.append(base)
            case "sample.zip":
                let source = Paths.join(folder, "sample")
                try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
                _ = try write(source, "readme.txt", "inside the zip\n")
                _ = try await Fixtures.copy("photo.jpg", to: source)
                let zip = Paths.join(folder, input)
                try await ProcessRunner.runOrThrow("/usr/bin/ditto", ["-c", "-k", "--keepParent", source, zip])
                try FileManager.default.removeItem(atPath: source)
                paths.append(zip)
            default:
                paths.append(try await Fixtures.copy(input, to: folder))
            }
        }
        return paths
    }

    private static func write(_ folder: String, _ name: String, _ text: String) throws -> String {
        let path = Paths.join(folder, name)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
}
