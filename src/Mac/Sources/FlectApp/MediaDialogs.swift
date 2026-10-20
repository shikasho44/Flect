import AppKit
import AVFoundation
import AVKit
import SwiftUI
import FlectCore
import FlectKit

@MainActor
final class Scrubber: ObservableObject {
    let player: AVPlayer
    let duration: Double
    @Published var position = 0.0
    @Published var playing = false
    @Published var previewable = true
    private var observer: Any?
    private var status: NSKeyValueObservation?
    var stopAt: (() -> Double?)?

    init(path: String, duration: Double) {
        self.duration = duration
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        status = item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            DispatchQueue.main.async { MainActor.assumeIsolated { if failed { self?.previewable = false } } }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                self.position = min(max(time.seconds, 0), duration)
                if let end = self.stopAt?(), self.position >= end { self.pause() }
                if self.player.rate == 0, self.position >= duration - 0.05 { self.playing = false }
            }
        }
    }

    func seek(_ seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle(from start: Double? = nil) {
        if playing {
            pause()
            return
        }
        if let start { seek(start) }
        player.play()
        playing = true
    }

    func pause() {
        player.pause()
        playing = false
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        status = nil
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct ScrubberControls: View {
    @ObservedObject var scrubber: Scrubber
    var playFrom: () -> Double?

    var body: some View {
        VStack(spacing: 8) {
            if scrubber.previewable {
                PlayerView(player: scrubber.player)
                    .frame(minHeight: 240)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Slider(value: Binding(get: { scrubber.position }, set: { scrubber.seek($0) }), in: 0...max(scrubber.duration, 0.1))
            HStack {
                Button(scrubber.playing ? Loc.t("dialog.trim.pause") : Loc.t("dialog.trim.play")) {
                    scrubber.toggle(from: playFrom())
                }
                .disabled(!scrubber.previewable)
                Text(Formatting.timecode(scrubber.position)).monospacedDigit()
                Spacer()
                Text(Formatting.timecode(scrubber.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
enum TrimDialog {
    static func ask(path: String, duration: Double) async -> TrimRange? {
        let scrubber = Scrubber(path: path, duration: duration)
        defer { scrubber.stop() }
        return await Dialog.ask("\(Branding.name) - \(Loc.t("dialog.trim.title"))", size: NSSize(width: 640, height: 560),
                                resizable: true) { finish in
            TrimView(scrubber: scrubber, finish: finish)
        }
    }
}

struct TrimView: View {
    @ObservedObject var scrubber: Scrubber
    var finish: (TrimRange?) -> Void
    @State private var start = Formatting.timecode(0)
    @State private var end = ""
    @State private var problem = ""

    private var range: TrimRange? {
        guard let from = Formatting.parseTimecode(start), let to = Formatting.parseTimecode(end) else { return nil }
        return TrimRange(start: from, end: to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Hint(Loc.t("dialog.trim.hint"))
            ScrubberControls(scrubber: scrubber) {
                guard let range, scrubber.position >= range.end else { return nil }
                return range.start
            }
            HStack(spacing: 12) {
                Button(Loc.t("dialog.trim.setStart")) { start = Formatting.timecode(scrubber.position) }
                Button(Loc.t("dialog.trim.setEnd")) { end = Formatting.timecode(scrubber.position) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(Loc.t("dialog.trim.start"))
                    TextField("", text: $start).frame(width: 120)
                }
                GridRow {
                    Text(Loc.t("dialog.trim.end"))
                    TextField("", text: $end).frame(width: 120)
                }
            }
            if let range, range.duration > 0 {
                Text(Loc.f("dialog.trim.selection", Formatting.timecode(range.duration))).foregroundStyle(.secondary)
            }
            ErrorLine(text: problem)
            DialogButtons(accept: Loc.t("dialog.trim.action"), onCancel: { finish(nil) }, onAccept: accept)
        }
        .padding(20)
        .onAppear {
            end = Formatting.timecode(scrubber.duration)
            scrubber.stopAt = { Formatting.parseTimecode(end) }
        }
    }

    private func accept() {
        guard let range else {
            problem = Loc.t("dialog.trim.invalid")
            return
        }
        if range.start >= range.end {
            problem = Loc.t("dialog.trim.backwards")
            return
        }
        if range.start >= scrubber.duration {
            problem = Loc.t("dialog.trim.past")
            return
        }
        finish(range)
    }
}

@MainActor
enum ThumbnailDialog {
    static func ask(path: String, duration: Double) async -> Double? {
        let scrubber = Scrubber(path: path, duration: duration)
        defer { scrubber.stop() }
        return await Dialog.ask("\(Branding.name) - \(Loc.t("dialog.thumbnail.title"))", size: NSSize(width: 640, height: 520),
                                resizable: true) { finish in
            ThumbnailView(scrubber: scrubber, finish: finish)
        }
    }
}

struct ThumbnailView: View {
    @ObservedObject var scrubber: Scrubber
    var finish: (Double?) -> Void
    @State private var time = Formatting.timecode(0)
    @State private var problem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Hint(Loc.t("dialog.thumbnail.hint"))
            ScrubberControls(scrubber: scrubber) { nil }
            HStack(spacing: 12) {
                Button(Loc.t("dialog.thumbnail.set")) { time = Formatting.timecode(scrubber.position) }
                Text(Loc.t("dialog.thumbnail.time"))
                TextField("", text: $time).frame(width: 120)
            }
            if let seconds = Formatting.parseTimecode(time) {
                Text(Loc.f("dialog.thumbnail.selection", Formatting.timecode(seconds))).foregroundStyle(.secondary)
            }
            ErrorLine(text: problem)
            DialogButtons(accept: Loc.t("dialog.thumbnail.action"), onCancel: { finish(nil) }) {
                guard let seconds = Formatting.parseTimecode(time) else {
                    problem = Loc.t("dialog.thumbnail.invalid")
                    return
                }
                if seconds > scrubber.duration {
                    problem = Loc.t("dialog.thumbnail.past")
                    return
                }
                finish(seconds)
            }
        }
        .padding(20)
    }
}
