import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FlectCore
import FlectKit

@MainActor
enum FileAnalyzeWindow {
    static func show(_ report: FileReport) {
        _ = WindowRegistry.shared.show("\(Branding.name) - \(Loc.t("dialog.fileAnalyze.title"))",
                                       size: NSSize(width: 760, height: 720), resizable: true) {
            FileAnalyzeView(report: report, actions: Suggest(path: report.path, settings: AppSettings.current))
        }
    }
}

struct FileAnalyzeView: View {
    let report: FileReport
    let actions: Suggest
    @State private var hash: String?
    @State private var hashError: String?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text((report.path as NSString).lastPathComponent).font(.title3.weight(.semibold)).lineLimit(2)
                Text(report.path)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .help(report.path + "\n" + Loc.t("dialog.fileAnalyze.pathHint"))
                    .onTapGesture { usePath() }
                    .accessibilityAddTraits(.isButton)
                HStack(spacing: 8) {
                    Text("SHA-256").font(.callout).foregroundStyle(.secondary)
                    Text(hash ?? hashError ?? Loc.t("dialog.fileAnalyze.hashPending"))
                        .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .help(hash == nil ? "" : Loc.t("dialog.fileAnalyze.copyHint"))
                        .onTapGesture { if let hash { copy(hash) } }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !report.alerts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(report.alerts.enumerated()), id: \.offset) { _, alert in
                                Label(alert, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red).textSelection(.enabled)
                            }
                        }
                    }
                    facts(report.overview)
                    ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.headline)
                            facts(section.rows)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }

            HStack {
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(Loc.t("dialog.analyze.save")) { Task { await save() } }
                Button(Loc.t("common.close")) { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task {
            let path = report.path
            do {
                hash = try await Task.detached(priority: .utility) { try Checksum.sha256(path) }.value
            } catch is CancellationError {
            } catch {
                hashError = describe(error)
            }
        }
    }

    private func facts(_ rows: [FileFact]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.label).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                    value(fact)
                    action(actions.link(fact.key))
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func value(_ fact: FileFact) -> some View {
        if Suggest.canCopy(fact.key) {
            Text(fact.value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(Loc.t("dialog.fileAnalyze.copyHint"))
                .onTapGesture { copy(fact.value) }
                .accessibilityAddTraits(.isButton)
        } else {
            Text(fact.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func action(_ link: SuggestLink?) -> some View {
        if let link {
            if link.direct, let command = link.commands.first {
                Button(link.label) { run(command.verb) }.buttonStyle(.link)
            } else {
                Menu(link.label) {
                    ForEach(Array(link.commands.enumerated()), id: \.offset) { _, command in
                        Button(command.label) { run(command.verb) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Color.flectAccent)
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func run(_ verb: String) {
        let path = report.path
        Task { await TaskRunner.run(verb: verb, paths: [path]) }
    }

    // A click copies the path; with ⇧ or ⌘ it shows the file in Finder, as Shift/Ctrl-click opens Explorer on Windows.
    private func usePath() {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) || modifiers.contains(.command) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.path)])
        } else {
            copy(report.path)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        note = NSPasteboard.general.setString(text, forType: .string) ? Loc.t("common.copied") : Loc.t("common.copyFailed")
    }

    private func save() async {
        let format = AppSettings.current.folder.analyze.saveFormat
        let panel = NSSavePanel()
        let ext = ReportWriter.fileExtension(format)
        panel.nameFieldStringValue = "\(Branding.name)-file.\(ext)"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var sha = hash
            if sha == nil {
                let path = report.path
                sha = try await Task.detached(priority: .userInitiated) { try Checksum.sha256(path) }.value
                hash = sha
            }
            try ReportFile.write(report, sha256: sha, to: url.path, format: format)
            note = Loc.f("dialog.analyze.saved", url.path)
        } catch {
            Dialog.error(Loc.f("dialog.analyze.saveFailed", describe(error)))
        }
    }
}
