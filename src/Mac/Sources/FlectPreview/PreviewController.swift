import AppKit
import QuickLookUI
import FlectKit
import FlectPreviewKit

@objc(FlectPreviewController)
final class PreviewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        Loc.use(Settings.load().general.language)
        let content = try PreviewBuilder.build(url)
        await MainActor.run {
            let preview = PreviewView.make(content)
            preview.frame = view.bounds
            preview.autoresizingMask = [.width, .height]
            view.addSubview(preview)
        }
    }
}
