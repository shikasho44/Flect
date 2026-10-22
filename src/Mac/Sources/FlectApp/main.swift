import AppKit
import FlectCore
import FlectKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledLaunchRequest = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let settings = AppSettings.current
        Loc.use(settings.general.language)
        Theme.apply(settings.general.theme)
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Handoff.ensureToken()
        NSApp.servicesProvider = ServiceProvider.shared
        NSUpdateDynamicServices()

        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--snapshots"), index + 1 < CommandLine.arguments.count {
            handledLaunchRequest = true
            let folder = CommandLine.arguments[index + 1]
            Task { await Snapshots.run(into: folder) }
            return
        }
        #endif

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--task"), index + 1 < arguments.count,
           let request = Request(arguments: Array(arguments.dropFirst())) {
            handledLaunchRequest = true
            Task { await TaskRunner.run(verb: arguments[index + 1], paths: request.paths) }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                if !self.handledLaunchRequest { SettingsWindow.show() }
                if AppSettings.current.general.autoUpdate, Updater.isDue {
                    Task { _ = await UpdateCheck.run(interactive: false) }
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunchRequest = true
        let handoffs = urls.filter { $0.scheme?.lowercased() == Branding.urlScheme }
        let files = urls.filter(\.isFileURL)
        for url in handoffs {
            Task { await TaskRunner.handoff(url) }
        }
        if !files.isEmpty { ActionPicker.show(files) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.show() }
        return true
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: Loc.t("app.credit") + "\nhttps://github.com/Konayukiw/Flect\nApache License 2.0",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11)])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showPicker(_ sender: Any?) { ActionPicker.show([]) }
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: Loc.t("app.about"), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: Loc.t("app.settings"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenu()
        let servicesItem = app.addItem(withTitle: Loc.t("app.menu.services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: Loc.t("app.menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: Loc.t("app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: Branding.name, action: nil, keyEquivalent: "").submenu = app

        let file = NSMenu(title: Loc.t("app.menu.file"))
        file.addItem(withTitle: Loc.t("picker.title"), action: #selector(AppDelegate.showPicker(_:)), keyEquivalent: "o")
        file.addItem(withTitle: Loc.t("common.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: file.title, action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: Loc.t("app.menu.edit"))
        edit.addItem(withTitle: Loc.t("app.menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: Loc.t("app.menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: Loc.t("app.menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: Loc.t("common.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: Loc.t("app.menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: Loc.t("app.menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: edit.title, action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: Loc.t("app.menu.window"))
        window.addItem(withTitle: Loc.t("app.menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: window.title, action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return main
    }
}

@MainActor
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    @objc func showActions(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { ActionPicker.show(urls) }
    }
}

@MainActor
enum UpdateCheck {
    static func run(interactive: Bool) async -> String {
        do {
            guard let update = try await Updater.check() else {
                return interactive ? Loc.t("settings.general.update.latest") : ""
            }
            if interactive { return confirm(update) }
            let alert = NSAlert()
            alert.messageText = Branding.name
            alert.informativeText = Loc.f("update.available", update.version, Branding.version)
            alert.addButton(withTitle: Loc.t("update.download"))
            alert.addButton(withTitle: Loc.t("update.later"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.download ?? update.page)
            }
            return Loc.f("update.available", update.version, Branding.version)
        } catch {
            return interactive ? Loc.t("settings.general.update.failed") : ""
        }
    }

    // The settings button, as in Windows 1.1. The dmg downloads through the browser, so macOS checks the new version
    // the first time it opens instead of Flect replacing itself unseen.
    private static func confirm(_ update: UpdateInfo) -> String {
        let alert = NSAlert()
        alert.messageText = Branding.name
        alert.informativeText = Loc.f("settings.general.update.confirm", update.version)
        alert.addButton(withTitle: Loc.t("update.download"))
        alert.addButton(withTitle: Loc.t("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return "" }
        NSWorkspace.shared.open(update.download ?? update.page)
        return Loc.f("update.opened", update.version)
    }
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
