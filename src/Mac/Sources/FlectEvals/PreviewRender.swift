import AppKit
import FlectKit
import FlectPreviewKit

// FlectEvals --render-preview <file> <out.png> [dark]: draws what Quick Look would show, without a window.
enum PreviewRender {
    @MainActor
    static func run(_ input: String, _ output: String, dark: Bool) throws {
        let arguments = CommandLine.arguments
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var image: NSBitmapImageRep?
        let content = try PreviewBuilder.build(URL(fileURLWithPath: input))
        appearance.performAsCurrentDrawingAppearance {
            let view = PreviewView.make(content)
            view.appearance = appearance
            view.frame = NSRect(x: 0, y: 0, width: 760, height: arguments.contains("short") ? 380 : 560)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            image = rep
        }
        guard let data = image?.representation(using: .png, properties: [:]) else {
            throw EvalFailure(description: "could not render \(input)")
        }
        try data.write(to: URL(fileURLWithPath: output))
    }
}
