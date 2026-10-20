import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FlectCore
import FlectKit

@MainActor
enum AnalyzeWindow {
    static func show(_ report: AnalyzeReport) {
        _ = WindowRegistry.shared.show("\(Branding.name) - \(Loc.t("dialog.analyze.title"))",
                                       size: NSSize(width: 720, height: 640), resizable: true) {
            AnalyzeView(report: report)
        }
    }
}

struct AnalyzeView: View {
    let report: AnalyzeReport
    @State private var saved = ""

    private struct TypeRow: Identifiable {
        let id = UUID()
        let label: String
        let bytes: Int64
        let count: Int
    }

    private var typeRows: [TypeRow] {
        var rows = report.byType.prefix(AnalyzeReport.topCount).map {
            TypeRow(label: $0.fileExtension, bytes: $0.bytes, count: $0.count)
        }
        let rest = report.byType.dropFirst(AnalyzeReport.topCount)
        if !rest.isEmpty {
            rows.append(TypeRow(label: Loc.f("dialog.analyze.moreTypes", Formatting.count(rest.count)),
                                bytes: rest.reduce(0) { $0 + $1.bytes }, count: rest.reduce(0) { $0 + $1.count }))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.roots.joined(separator: "   ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 12) {
                tile(Formatting.bytes(report.totalBytes), Loc.t("dialog.analyze.total"))
                tile(Formatting.count(report.fileCount), Loc.t("dialog.analyze.files"))
                tile(Formatting.count(report.directoryCount), Loc.t("dialog.analyze.folders"))
                tile(String(format: "%.1fs", report.elapsed), Loc.t("dialog.analyze.scanTime"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(Loc.t("dialog.analyze.largest")) {
                        ForEach(report.largest, id: \.path) { file in
                            HStack {
                                Text(Formatting.bytes(file.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
                                Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path)
                            }
                        }
                    }
                    section(Loc.t("dialog.analyze.types")) {
                        let total = Double(max(1, report.totalBytes))
                        let largest = Double(max(1, typeRows.first?.bytes ?? 1))
                        ForEach(typeRows) { row in
                            HStack(spacing: 10) {
                                Text(row.label).frame(width: 110, alignment: .leading).lineLimit(1)
                                Capsule().fill(Color.flectAccent)
                                    .frame(width: max(2, CGFloat(Double(row.bytes) / largest) * 140), height: 8)
                                    .frame(width: 140, alignment: .leading)
                                Text(Formatting.bytes(row.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                Text(Formatting.percent(Double(row.bytes) / total)).monospacedDigit().frame(width: 60, alignment: .trailing)
                                Text(Loc.n("count.file", row.count)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    section(Loc.t("dialog.analyze.duplicates")) {
                        Text(report.duplicateGroups == 0
                             ? Loc.t("dialog.analyze.none")
                             : Loc.f("dialog.analyze.dupSummary", Loc.n("count.group", report.duplicateGroups),
                                     Loc.n("count.file", report.duplicateFiles), Formatting.bytes(report.reclaimableBytes)))
                    }
                    section(Loc.t("dialog.analyze.empty")) {
                        Text(report.emptyDirectories.isEmpty ? Loc.t("dialog.analyze.none")
                                                              : Loc.n("count.folder", report.emptyDirectories.count))
                        ForEach(report.emptyDirectories.prefix(60), id: \.self) { folder in
                            Text(folder).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(saved).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(Loc.t("dialog.analyze.save"), action: save)
                Button(Loc.t("common.close")) { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func save() {
        let format = AppSettings.current.folder.analyze.saveFormat
        let panel = NSSavePanel()
        let ext = ReportWriter.fileExtension(format)
        panel.nameFieldStringValue = "\(Branding.name)-analyze.\(ext)"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ReportWriter.write(report, to: url.path, format: format)
            saved = Loc.f("dialog.analyze.saved", url.path)
        } catch {
            Dialog.error(Loc.f("dialog.analyze.saveFailed", describe(error)))
        }
    }
}
