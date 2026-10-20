#if DEBUG
import AppKit
import FlectCore
import FlectKit

@MainActor
enum Snapshots {
    static func run(into folder: String) async {
        NSApp.setActivationPolicy(.accessory)
        WindowRegistry.shared.offscreen = true
        AppLifecycle.shared.keepAlive = true
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for page in SettingsPage.allCases {
                SettingsWindow.show(page: page)
                await capture("settings-\(page.rawValue)-\(suffix)", folder)
            }
            await sample("progress-\(suffix)", folder) { showProgress() }
            await sample("resize-\(suffix)", folder) { Task { _ = await PixelsDialog.ask() } }
            await sample("target-\(suffix)", folder) { Task { _ = await TargetBytesDialog.ask(largest: 12_582_912) } }
            await sample("rename-\(suffix)", folder) { Task { _ = await RenameDialog.ask(sampleExtension: ".png") } }
            await sample("duplicates-\(suffix)", folder) { Task { _ = await DuplicateDialog.ask(duplicateGroups) } }
            await sample("pdf-order-\(suffix)", folder) {
                Task { _ = await PdfOrderDialog.ask(["/tmp/alpha.pdf", "/tmp/bravo.pdf", "/tmp/charlie.pdf"]) }
            }
            await sample("tree-\(suffix)", folder) {
                TextResultWindow.show(title: Loc.t("menu.folder.tree"), text: "/Users/me/Photos\n├───2025\n│   └───beach.jpg\n└───notes.txt\n")
            }
            await sample("analyze-\(suffix)", folder) { AnalyzeWindow.show(analyzeReport) }
            await sample("picker-\(suffix)", folder) {
                ActionPicker.show([URL(fileURLWithPath: "/tmp/photo.png"), URL(fileURLWithPath: "/tmp/scan.png")])
            }
        }
        NSApp.terminate(nil)
    }

    private static func sample(_ name: String, _ folder: String, _ open: () -> Void) async {
        open()
        await capture(name, folder)
    }

    private static func capture(_ name: String, _ folder: String) async {
        try? await Task.sleep(nanoseconds: 700_000_000)
        for window in WindowRegistry.shared.open {
            if let view = window.contentView?.superview ?? window.contentView {
                view.layoutSubtreeIfNeeded()
                if let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: representation)
                    let path = (folder as NSString).appendingPathComponent("\(name).png")
                    try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            window.close()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private static func showProgress() {
        let model = ProgressModel(heading: Loc.t("menu.video.compress"))
        model.status = "clip.mp4 - Encoding 1280x720@24fps · 812kbps - 64%"
        model.fraction = 0.4
        model.append(.information, Loc.f("msg.alreadySmall", "small.mp4", "3.20 MB"))
        model.append(.warning, Loc.f("msg.overTarget", "long.mov", "21.4 MB", "20.0 MB"))
        _ = WindowRegistry.shared.show("\(Branding.name) - \(model.heading)", size: NSSize(width: 480, height: 300)) {
            ProgressPanel(model: model)
        }
    }

    private static var duplicateGroups: [[ScannedFile]] {
        let now = Date()
        return [
            [ScannedFile(path: "/Users/me/Pictures/IMG_0001.jpg", size: 2_400_000, lastWrite: now.addingTimeInterval(-86_400), fileExtension: "jpg"),
             ScannedFile(path: "/Users/me/Downloads/IMG_0001 (2).jpg", size: 2_400_000, lastWrite: now, fileExtension: "jpg")],
            [ScannedFile(path: "/Users/me/Documents/report.pdf", size: 520_000, lastWrite: now.addingTimeInterval(-500), fileExtension: "pdf"),
             ScannedFile(path: "/Users/me/Desktop/report copy.pdf", size: 520_000, lastWrite: now, fileExtension: "pdf"),
             ScannedFile(path: "/Users/me/Desktop/old/report.pdf", size: 520_000, lastWrite: now.addingTimeInterval(-90_000), fileExtension: "pdf")],
        ]
    }

    private static var analyzeReport: AnalyzeReport {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("flect-snapshot-analyze")
        try? FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent("empty"), withIntermediateDirectories: true)
        for (name, size) in [("movie.mov", 4_000_000), ("photo.jpg", 900_000), ("copy.jpg", 900_000), ("notes.txt", 2_000)] {
            FileManager.default.createFile(atPath: (folder as NSString).appendingPathComponent(name), contents: Data(count: size))
        }
        let scan = try? FileScanner.scan([folder], progress: SilentProgress(), options: .from(AppSettings().folder))
        let duplicates = (try? FileScanner.findDuplicates(scan?.files ?? [], progress: SilentProgress(),
                                                          settings: AppSettings().folder.duplicates)) ?? []
        return AnalyzeReport.build([folder], scan ?? TreeScan(), duplicates, elapsed: 0.42)
    }
}
#endif
