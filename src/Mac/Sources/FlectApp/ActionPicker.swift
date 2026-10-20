import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FlectCore
import FlectKit

@MainActor
enum ActionPicker {
    static func show(_ urls: [URL]) {
        let model = PickerModel(urls)
        var window: NSWindow?
        model.onRun = { verb, paths in
            window?.close()
            Task { await TaskRunner.run(verb: verb, paths: paths) }
        }
        window = WindowRegistry.shared.show("\(Branding.name) - \(Loc.t("picker.title"))", size: NSSize(width: 420, height: 520),
                                            resizable: true) {
            PickerView(model: model)
        }
    }
}

@MainActor
final class PickerModel: ObservableObject {
    @Published var selection: SelectionInfo
    @Published var nodes: [MenuNode]
    var onRun: (String, [String]) -> Void = { _, _ in }

    init(_ urls: [URL]) {
        selection = SelectionInfo()
        nodes = []
        load(urls)
    }

    func load(_ urls: [URL]) {
        selection = Selection.classify(urls, inspect: true)
        nodes = MenuBuilder.build(selection, settings: AppSettings.current)
    }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.selection.paths.isEmpty {
                Spacer()
                Text(Loc.t("picker.drop")).frame(maxWidth: .infinity).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text(Loc.f("picker.selection", model.selection.paths.count == 1
                           ? (model.selection.paths[0] as NSString).lastPathComponent
                           : Loc.n("count.file", model.selection.paths.count)))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.nodes.isEmpty {
                    Hint(Loc.t("picker.none"))
                    Spacer()
                } else {
                    List {
                        ForEach(model.nodes, id: \.id) { node in
                            NodeRow(node: node) { verb in model.onRun(verb, model.selection.paths) }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(16)
        .background(targeted ? Color.flectAccent.opacity(0.12) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let parsed = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(parsed)
                    }
                }
                if !urls.isEmpty { model.load(urls) }
            }
            return true
        }
    }
}

private struct NodeRow: View {
    let node: MenuNode
    let run: (String) -> Void
    @State private var expanded = true

    var body: some View {
        if node.children.isEmpty {
            Button {
                if let verb = node.verb { run(verb) }
            } label: {
                Text(node.label).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children, id: \.id) { child in NodeRow(node: child, run: run) }
            } label: {
                Text(node.label).font(.body.weight(.medium))
            }
        }
    }
}
