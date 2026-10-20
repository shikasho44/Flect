import AppKit
import PDFKit
import SwiftUI
import FlectCore
import FlectKit

@MainActor
enum PixelsDialog {
    static func ask() async -> PixelTarget? {
        await Dialog.ask("\(Branding.name) - \(Loc.t("menu.image.resize"))", size: NSSize(width: 380, height: 220)) { finish in
            PixelsView(finish: finish)
        }
    }
}

struct PixelsView: View {
    var finish: (PixelTarget?) -> Void
    @State private var width = ""
    @State private var height = ""
    @State private var keepAspect = true
    @State private var problem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Hint(Loc.t("dialog.resize.hint"))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(Loc.t("dialog.resize.width"))
                    TextField("", text: $width).frame(width: 120)
                }
                GridRow {
                    Text(Loc.t("dialog.resize.height"))
                    TextField("", text: $height).frame(width: 120)
                }
            }
            Toggle(Loc.t("dialog.resize.keepAspect"), isOn: $keepAspect)
            ErrorLine(text: problem)
            DialogButtons(accept: Loc.t("dialog.resize.action"), onCancel: { finish(nil) }, onAccept: accept)
        }
        .padding(20)
    }

    private func accept() {
        let w = Int(width.trimmingCharacters(in: .whitespaces)) ?? 0
        let h = Int(height.trimmingCharacters(in: .whitespaces)) ?? 0
        if w <= 0, h <= 0 {
            problem = Loc.t("dialog.pixels.empty")
            return
        }
        if w > 100_000 || h > 100_000 {
            problem = Loc.t("dialog.pixels.tooLarge")
            return
        }
        finish(PixelTarget(width: max(0, w), height: max(0, h), keepAspect: keepAspect))
    }
}

@MainActor
enum TargetBytesDialog {
    static func ask(largest: Int64) async -> Int64? {
        await Dialog.ask("\(Branding.name) - \(Loc.t("dialog.target.title"))", size: NSSize(width: 400, height: 200)) { finish in
            TargetBytesView(largest: largest, finish: finish)
        }
    }
}

struct TargetBytesView: View {
    var largest: Int64
    var finish: (Int64?) -> Void
    @State private var text = ""
    @State private var problem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Loc.t("dialog.target.label")).font(.headline)
            TextField("8MB", text: $text)
            if let bytes = Formatting.parseBytes(text) {
                Text(Loc.f("dialog.target.echo", Formatting.count(Int(bytes)))).font(.callout).foregroundStyle(.secondary)
            }
            Hint(largest > 0 ? Loc.f("dialog.target.largest", Formatting.bytes(largest), Loc.t("dialog.target.syntax"))
                             : Loc.t("dialog.target.syntax"))
            ErrorLine(text: problem)
            DialogButtons(accept: Loc.t("dialog.target.action"), onCancel: { finish(nil) }) {
                guard let bytes = Formatting.parseBytes(text) else {
                    problem = Loc.t("dialog.target.invalid")
                    return
                }
                finish(bytes)
            }
        }
        .padding(20)
    }
}

@MainActor
enum RenameDialog {
    static func ask(sampleExtension: String) async -> RenamePlan? {
        await Dialog.ask("\(Branding.name) - \(Loc.t("dialog.rename.title"))", size: NSSize(width: 440, height: 300)) { finish in
            RenameView(sampleExtension: sampleExtension, finish: finish)
        }
    }
}

struct RenameView: View {
    var sampleExtension: String
    var finish: (RenamePlan?) -> Void
    @State private var prefix = ""
    @State private var name = ""
    @State private var suffix = ""
    @State private var numbering = AppSettings.current.folder.rename.useNumbering
    @State private var problem = ""

    private var preview: String {
        let settings = AppSettings.current.folder.rename
        let middle = numbering
            ? String(settings.startNumber).leftPadded(settings.digitCount > 0 ? settings.digitCount : 3, with: "0")
            : name
        let first = "\(prefix)\(middle)\(suffix)\(sampleExtension)"
        return numbering ? first : "\(first)   \(prefix)\(middle)\(suffix) (2)\(sampleExtension)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Hint(Loc.t("dialog.rename.body"))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(Loc.t("dialog.rename.prefix"))
                    TextField("", text: $prefix)
                }
                GridRow {
                    Text(Loc.t("dialog.rename.name")).foregroundStyle(numbering ? .secondary : .primary)
                    TextField("", text: $name).disabled(numbering)
                }
                GridRow {
                    Text(Loc.t("dialog.rename.suffix"))
                    TextField("", text: $suffix)
                }
            }
            Toggle(Loc.t("dialog.rename.numbering"), isOn: $numbering)
            HStack(spacing: 6) {
                Text(Loc.t("dialog.rename.preview")).foregroundStyle(.secondary)
                Text(preview).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            ErrorLine(text: problem)
            DialogButtons(accept: Loc.t("dialog.rename.action"), onCancel: { finish(nil) }, onAccept: accept)
        }
        .padding(20)
    }

    private func accept() {
        let whole = prefix + (numbering ? "1" : name) + suffix
        if whole.trimmingCharacters(in: .whitespaces).isEmpty {
            problem = Loc.t(numbering ? "dialog.rename.needAffix" : "dialog.rename.needName")
            return
        }
        if whole.contains("/") || whole.contains(":") {
            problem = Loc.t("dialog.rename.invalidChars")
            return
        }
        finish(RenamePlan(prefix: prefix, name: name, suffix: suffix, numbered: numbering))
    }
}

@MainActor
enum DuplicateDialog {
    static func ask(_ groups: [[ScannedFile]]) async -> DuplicateMode? {
        await Dialog.ask("\(Branding.name) - \(Loc.t("menu.folder.removeDuplicate"))", size: NSSize(width: 640, height: 520),
                         resizable: true) { finish in
            DuplicateView(groups: groups, finish: finish)
        }
    }
}

struct DuplicateView: View {
    var groups: [[ScannedFile]]
    var finish: (DuplicateMode?) -> Void
    @State private var mode = DuplicateMode.keepOldest

    private var doomed: Set<String> { Set(DuplicatePlan.toDelete(groups, mode: mode).map(\.path)) }

    var body: some View {
        let removing = doomed
        let copies = groups.reduce(0) { $0 + $1.count }
        let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.size } - $1[0].size }
        let freed = groups.joined().filter { removing.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }

        VStack(alignment: .leading, spacing: 12) {
            Text(Loc.f("dialog.duplicate.found", Loc.n("count.group", groups.count), Loc.n("count.file", copies),
                       Formatting.bytes(reclaimable)))
                .font(.headline)
            Picker("", selection: $mode) {
                Text(Loc.t("dialog.duplicate.keepOldest")).tag(DuplicateMode.keepOldest)
                Text(Loc.t("dialog.duplicate.keepNewest")).tag(DuplicateMode.keepNewest)
                Text(Loc.t("dialog.duplicate.deleteAll")).tag(DuplicateMode.deleteAll)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            List {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Section(Loc.f("dialog.duplicate.groupHeader", Loc.n("count.identical", group.count),
                                  Formatting.bytes(group[0].size))) {
                        ForEach(group.sorted { $0.lastWrite < $1.lastWrite }, id: \.path) { file in
                            HStack(spacing: 10) {
                                Text(Loc.t(removing.contains(file.path) ? "dialog.duplicate.remove" : "dialog.duplicate.keep"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(removing.contains(file.path) ? .red : .green)
                                    .frame(width: 60, alignment: .leading)
                                Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path)
                            }
                        }
                    }
                }
            }
            .listStyle(.bordered)

            HStack {
                Text("\(Loc.n("count.file", removing.count)) · \(Formatting.bytes(freed))").foregroundStyle(.secondary)
                Spacer()
            }
            DialogButtons(accept: Loc.t(AppSettings.current.folder.deleteMethod == .permanent ? "dialog.duplicate.delete"
                                                                                            : "dialog.duplicate.recycle"),
                          acceptEnabled: !removing.isEmpty, onCancel: { finish(nil) }, onAccept: { finish(mode) })
        }
        .padding(20)
    }
}

@MainActor
enum PdfOrderDialog {
    static func ask(_ paths: [String]) async -> [String]? {
        await Dialog.ask("\(Branding.name) - \(Loc.t("dialog.pdfOrder.title"))", size: NSSize(width: 480, height: 400),
                         resizable: true) { finish in
            PdfOrderView(paths: paths, finish: finish)
        }
    }
}

struct PdfOrderView: View {
    @State var paths: [String]
    var finish: ([String]?) -> Void
    @State private var selection: String?

    init(paths: [String], finish: @escaping ([String]?) -> Void) {
        _paths = State(initialValue: paths)
        _selection = State(initialValue: paths.first)
        self.finish = finish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Hint(Loc.t("dialog.pdfOrder.body"))
            List(selection: $selection) {
                ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(path)
                }
                .onMove { paths.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            HStack {
                Button(Loc.t("dialog.pdfOrder.up")) { move(-1) }.disabled(index.map { $0 == 0 } ?? true)
                Button(Loc.t("dialog.pdfOrder.down")) { move(1) }.disabled(index.map { $0 == paths.count - 1 } ?? true)
                Spacer()
            }
            DialogButtons(accept: Loc.t("menu.pdf.merge"), onCancel: { finish(nil) }, onAccept: { finish(paths) })
        }
        .padding(20)
    }

    private var index: Int? { selection.flatMap { paths.firstIndex(of: $0) } }

    private func move(_ offset: Int) {
        guard let from = index, paths.indices.contains(from + offset) else { return }
        paths.swapAt(from, from + offset)
    }
}

@MainActor
enum TextResultWindow {
    static func show(title: String, text: String) {
        _ = WindowRegistry.shared.show("\(Branding.name) - \(title)", size: NSSize(width: 640, height: 480), resizable: true) {
            TextResultView(heading: title, text: text)
        }
    }
}

struct TextResultView: View {
    var heading: String
    var text: String
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.title3.weight(.semibold))
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button(copied ?? Loc.t("common.copy")) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text, forType: .string) ? Loc.t("common.copied") : Loc.t("common.copyFailed")
                }
                Button(Loc.t("common.close")) { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

@MainActor
enum PdfPreviewWindow {
    static func show(_ path: String) {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            Dialog.error("This document could not be read.")
            return
        }
        _ = WindowRegistry.shared.show("\(Branding.name) - \((path as NSString).lastPathComponent)",
                                       size: NSSize(width: 760, height: 900), resizable: true) {
            PdfPreviewView(document: document)
        }
    }
}

private struct PdfPreviewView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

extension String {
    func leftPadded(_ width: Int, with pad: Character) -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
