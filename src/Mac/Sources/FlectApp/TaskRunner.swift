import AppKit
import SwiftUI
import FlectCore
import FlectKit

@MainActor
enum TaskRunner {
    private static let menuParameters: Set<String> = ["to", "scale", "bytes", "deg", "preset"]

    static func handoff(_ url: URL) async {
        guard let (rawVerb, paths, token) = Handoff.parse(url) else { return }
        var verb = rawVerb
        if token == nil || token != Handoff.readToken() {
            verb = menuVerb(rawVerb)
            let name = Factory.label(for: verb)
            let subject = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : Loc.n("count.file", paths.count)
            guard Dialog.confirm(Loc.f("msg.handoffConfirm", name, subject)) else {
                AppLifecycle.shared.windowClosed()
                return
            }
        }
        await run(verb: verb, paths: paths)
    }

    static func menuVerb(_ verb: String) -> String {
        let parts = verb.split(separator: "?", maxSplits: 1)
        guard parts.count == 2 else { return verb }
        let kept = parts[1].split(separator: "&").filter { pair in
            menuParameters.contains(pair.split(separator: "=").first.map { $0.lowercased() } ?? "")
        }
        return kept.isEmpty ? String(parts[0]) : parts[0] + "?" + kept.joined(separator: "&")
    }

    static func run(verb: String, paths: [String]) async {
        guard let request = Request(verb: verb, paths: paths), let task = Factory.create(request) else {
            Dialog.error(Loc.f("msg.unknownCommand", verb))
            return
        }

        AppLifecycle.shared.taskStarted()
        defer { AppLifecycle.shared.taskEnded() }

        let ui = AppInteraction()
        guard await task.scoped({ await task.configure(ui) }) else { return }

        if !task.showsProgress {
            do {
                try await task.scoped { try await task.run(SilentProgress()) }
            } catch {
                Dialog.error(describe(error))
                return
            }
            await task.scoped { await task.present(ui) }
            return
        }

        let model = ProgressModel(heading: task.title)
        let reporter = ProgressReporter(model)
        var window: NSWindow?
        let worker = Task.detached(priority: .userInitiated) { try await task.scoped { try await task.run(reporter) } }
        model.onCancel = { worker.cancel() }
        model.onClose = { window?.close() }
        window = WindowRegistry.shared.show("\(Branding.name) - \(task.title)", size: NSSize(width: 480, height: 170),
                                            onClose: { worker.cancel() }) {
            ProgressPanel(model: model)
        }

        let outcome: TaskOutcome
        do {
            try await worker.value
            outcome = .succeeded
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            model.append(.error, describe(error))
            outcome = .failed
        }

        await Task.yield()
        if outcome == .succeeded { await task.scoped { await task.present(ui) } }
        if model.finish(outcome, summary: outcome == .succeeded ? task.summary : nil) { window?.close() }
    }
}

final class SilentProgress: TaskProgress {
    func status(_ text: String) {}
    func step(_ done: Int, _ total: Int) {}
    func indeterminate() {}
    func info(_ message: String) {}
    func warn(_ message: String) {}
    func error(_ message: String) {}
}

@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    private var activeTasks = 0
    var keepAlive = false

    func taskStarted() { activeTasks += 1 }

    func taskEnded() {
        activeTasks -= 1
        scheduleCheck()
    }

    func windowClosed() { scheduleCheck() }

    private func scheduleCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                guard !self.keepAlive, self.activeTasks == 0, WindowRegistry.shared.isEmpty,
                      NSApp.modalWindow == nil else { return }
                NSApp.terminate(nil)
            }
        }
    }
}

final class AppInteraction: Interaction {
    func askPixels() async -> PixelTarget? { await PixelsDialog.ask() }

    func askTargetBytes(largest: Int64) async -> Int64? { await TargetBytesDialog.ask(largest: largest) }

    func askTrim(path: String, duration: Double) async -> TrimRange? { await TrimDialog.ask(path: path, duration: duration) }

    func askThumbnail(path: String, duration: Double) async -> Double? {
        await ThumbnailDialog.ask(path: path, duration: duration)
    }

    func askRename(sampleExtension: String) async -> RenamePlan? { await RenameDialog.ask(sampleExtension: sampleExtension) }

    func askDuplicates(_ groups: [[ScannedFile]]) async -> DuplicateMode? { await DuplicateDialog.ask(groups) }

    func askPdfOrder(_ paths: [String]) async -> [String]? { await PdfOrderDialog.ask(paths) }

    func confirm(_ message: String) async -> Bool { await MainActor.run { Dialog.confirm(message) } }

    func reportError(_ message: String) async { await MainActor.run { Dialog.error(message) } }

    func showText(title: String, text: String) async { await TextResultWindow.show(title: title, text: text) }

    func showAnalyze(_ report: AnalyzeReport) async { await AnalyzeWindow.show(report) }

    func showPdfPreview(path: String) async { await PdfPreviewWindow.show(path) }

    func copyToClipboard(_ text: String) async -> Bool {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
