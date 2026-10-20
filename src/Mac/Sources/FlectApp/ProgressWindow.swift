import AppKit
import SwiftUI
import FlectCore
import FlectKit

enum LogSeverity {
    case information, warning, error
}

struct LogEntry: Identifiable {
    let id = UUID()
    let severity: LogSeverity
    let message: String
}

enum TaskOutcome {
    case succeeded, cancelled, failed
}

@MainActor
final class ProgressModel: ObservableObject {
    @Published var heading: String
    @Published var status = ""
    @Published var fraction: Double?
    @Published var log: [LogEntry] = []
    @Published var finished = false
    @Published var cancelling = false

    var errorCount = 0
    var warningCount = 0
    var onCancel: () -> Void = {}
    var onClose: () -> Void = {}

    init(heading: String) { self.heading = heading }

    func append(_ severity: LogSeverity, _ message: String) {
        if severity == .error { errorCount += 1 }
        if severity == .warning { warningCount += 1 }
        log.append(LogEntry(severity: severity, message: message))
    }

    func finish(_ outcome: TaskOutcome, summary: String?) -> Bool {
        finished = true
        fraction = outcome == .succeeded ? 1 : fraction ?? 0
        switch outcome {
        case .succeeded where errorCount > 0:
            status = summary ?? Loc.f("progress.problems", Loc.n("count.problem", errorCount))
        case .succeeded:
            status = summary ?? Loc.t("progress.done")
        case .cancelled:
            status = Loc.t("progress.cancelled")
        case .failed:
            status = Loc.t("progress.failed")
        }

        let general = AppSettings.current.general
        switch outcome {
        case .succeeded: return general.closeOnSuccess && errorCount == 0 && warningCount == 0
        case .cancelled: return general.closeOnCancel
        case .failed: return general.closeOnFailure
        }
    }
}

final class ProgressReporter: TaskProgress {
    private let model: ProgressModel

    init(_ model: ProgressModel) { self.model = model }

    private func post(_ change: @escaping @MainActor (ProgressModel) -> Void) {
        let model = self.model
        DispatchQueue.main.async { MainActor.assumeIsolated { change(model) } }
    }

    func status(_ text: String) { post { $0.status = text } }

    func step(_ done: Int, _ total: Int) {
        post { $0.fraction = Double(min(max(done, 0), max(total, 1))) / Double(max(total, 1)) }
    }

    func indeterminate() { post { $0.fraction = nil } }

    func info(_ message: String) { post { $0.append(.information, message) } }

    func warn(_ message: String) { post { $0.append(.warning, message) } }

    func error(_ message: String) { post { $0.append(.error, message) } }
}

struct ProgressPanel: View {
    @ObservedObject var model: ProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.heading)
                .font(.title3.weight(.semibold))
            Text(model.status.isEmpty ? " " : model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let fraction = model.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }

            if !model.log.isEmpty {
                ScrollViewReader { proxy in
                    List(model.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(entry.severity))
                                .foregroundStyle(color(entry.severity))
                            Text(entry.message)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(entry.id)
                    }
                    .listStyle(.bordered)
                    .frame(height: 150)
                    .onChange(of: model.log.count) {
                        if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            HStack {
                Spacer()
                if model.finished {
                    Button(Loc.t("common.close")) { model.onClose() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.cancelling ? Loc.t("progress.cancelling") : Loc.t("common.cancel")) {
                        model.cancelling = true
                        model.status = Loc.t("progress.cancelling")
                        model.onCancel()
                    }
                    .disabled(model.cancelling)
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
    }

    private func icon(_ severity: LogSeverity) -> String {
        switch severity {
        case .information: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ severity: LogSeverity) -> Color {
        switch severity {
        case .information: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
