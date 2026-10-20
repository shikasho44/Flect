import Cocoa
import FinderSync
import FlectKit

@objc(FlectFinderSync)
final class FinderSync: FIFinderSync {
    private lazy var icon: NSImage? = {
        let image = Bundle.main.image(forResource: "MenuIcon")
        image?.size = NSSize(width: 16, height: 16)
        return image
    }()

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override var toolbarItemName: String { Branding.name }

    override var toolbarItemToolTip: String { Branding.name }

    override var toolbarItemImage: NSImage {
        icon ?? NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: Branding.name) ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .toolbarItemMenu else { return nil }
        let nodes = currentNodes()
        guard !nodes.isEmpty else { return nil }

        var counter = 0
        let items = submenu(nodes, counter: &counter)
        if menuKind == .toolbarItemMenu { return items }

        let menu = NSMenu(title: "")
        let root = NSMenuItem(title: Branding.name, action: nil, keyEquivalent: "")
        root.image = icon
        root.submenu = items
        menu.addItem(root)
        return menu
    }

    private func currentNodes() -> [MenuNode] {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return [] }
        let settings = Settings.load()
        Loc.use(settings.general.language)
        return MenuBuilder.build(Selection.classify(urls, inspect: false), settings: settings)
    }

    private func submenu(_ nodes: [MenuNode], counter: inout Int) -> NSMenu {
        let menu = NSMenu(title: "")
        for node in nodes {
            let item = NSMenuItem(title: node.label, action: nil, keyEquivalent: "")
            if node.children.isEmpty {
                counter += 1
                item.tag = counter
                item.action = #selector(run(_:))
                item.target = self
            } else {
                item.submenu = submenu(node.children, counter: &counter)
            }
            menu.addItem(item)
        }
        return menu
    }

    private func leaves(_ nodes: [MenuNode]) -> [MenuNode] {
        nodes.flatMap { $0.children.isEmpty ? [$0] : leaves($0.children) }
    }

    @objc private func run(_ sender: NSMenuItem) {
        let available = leaves(currentNodes())
        guard sender.tag > 0, sender.tag <= available.count, let verb = available[sender.tag - 1].verb,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return }

        let paths = urls.map { $0.standardizedFileURL.path }
        guard let url = Handoff.url(verb: verb, paths: paths, token: Handoff.readToken()) else { return }
        NSWorkspace.shared.open(url)
    }
}
