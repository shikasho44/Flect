import AppKit
import SwiftUI
import FlectKit

typealias AppSettings = FlectKit.Settings

extension Color {
    static let flectAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x81 / 255, green: 0x8C / 255, blue: 0xF8 / 255, alpha: 1)
            : NSColor(srgbRed: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255, alpha: 1)
    })
}

enum Theme {
    static func apply(_ theme: AppTheme) {
        switch theme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

@MainActor
final class WindowRegistry: NSObject, NSWindowDelegate {
    static let shared = WindowRegistry()

    private var windows: [NSWindow: () -> Void] = [:]
    var offscreen = false

    func show<Content: View>(_ title: String, size: NSSize, resizable: Bool = false, floating: Bool = false,
                             onClose: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: WindowContent(fixedWidth: resizable ? nil : size.width,
                                                                     content: content().tint(.flectAccent)))
        controller.sizingOptions = resizable ? [] : [.preferredContentSize]
        window.contentViewController = controller
        if resizable { window.setContentSize(size) }
        if resizable { window.contentMinSize = NSSize(width: min(size.width, 420), height: min(size.height, 260)) }
        if floating { window.level = .floating }
        window.delegate = self
        windows[window] = onClose
        window.center()
        if offscreen { return window }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let onClose = windows.removeValue(forKey: window) else { return }
        onClose()
        AppLifecycle.shared.windowClosed()
    }

    var isEmpty: Bool { windows.isEmpty }

    var open: [NSWindow] { Array(windows.keys) }
}

private struct WindowContent<Content: View>: View {
    let fixedWidth: CGFloat?
    let content: Content

    var body: some View {
        if let fixedWidth {
            content.frame(width: fixedWidth).fixedSize(horizontal: false, vertical: true)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

@MainActor
enum Dialog {
    static func ask<Result, Content: View>(_ title: String, size: NSSize, resizable: Bool = false,
                                           @ViewBuilder content: @escaping (@escaping (Result?) -> Void) -> Content) async -> Result? {
        await withCheckedContinuation { continuation in
            var finished = false
            var window: NSWindow?
            let finish: (Result?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
                window?.close()
            }
            window = WindowRegistry.shared.show(title, size: size, resizable: resizable, floating: true,
                                                onClose: { finish(nil) }) {
                content(finish)
            }
        }
    }

    static func error(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Branding.name
        alert.informativeText = message
        alert.addButton(withTitle: Loc.t("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func info(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Branding.name
        alert.informativeText = message
        alert.addButton(withTitle: Loc.t("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func confirm(_ message: String, ok: String = Loc.t("common.ok")) -> Bool {
        let alert = NSAlert()
        alert.messageText = Branding.name
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: Loc.t("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct DialogButtons: View {
    var accept: String
    var acceptEnabled = true
    var onCancel: () -> Void
    var onAccept: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(Loc.t("common.cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(accept, action: onAccept)
                .keyboardShortcut(.defaultAction)
                .disabled(!acceptEnabled)
        }
    }
}

struct Hint: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ErrorLine: View {
    var text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
