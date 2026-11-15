import AppKit
import FlectKit

public struct PreviewContent {
    public let text: NSAttributedString
    public let notices: [String]
    public let refused: Bool
}

// What Quick Look shows for code, Markdown and HTML. HTML is shown as its source: it is never rendered, so no
// script runs and nothing is fetched, wherever the file came from.
public enum PreviewBuilder {
    public static let limit = 2 * 1024 * 1024

    public static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd"]
    public static let html: Set<String> = ["html", "htm", "xhtml"]

    public static func build(_ url: URL) throws -> PreviewContent {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let magic = Signature.of([UInt8](data.prefix(8192)), fileName: name)
        if !data.isEmpty, !["text", "image"].contains(magic.family) || (magic.family == "image" && magic.kind != "SVG") {
            let kind = magic.kind.isEmpty ? Loc.t("dialog.fileAnalyze.unknown") : magic.kind
            let notice = Loc.f("preview.mac.mismatch", name, kind)
            return PreviewContent(text: NSAttributedString(), notices: [notice], refused: true)
        }

        var notices: [String] = []
        let truncated = data.count > limit
        var text = decode(truncated ? data.prefix(limit) : data)
        if truncated {
            if let lastBreak = text.lastIndex(of: "\n") { text = String(text[...lastBreak]) }
            notices.append(Loc.f("preview.mac.truncated", ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))
        }

        if markdown.contains(ext) { return PreviewContent(text: MarkdownRenderer.render(text), notices: notices, refused: false) }
        if html.contains(ext) { notices.append(Loc.t("preview.mac.htmlSource")) }
        return PreviewContent(text: Highlighter.highlight(text, extension: ext), notices: notices, refused: false)
    }

    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        // A cut-off multibyte character at the end is not a reason to give up on UTF-8.
        if data.count > 4, let text = String(data: data.dropLast(3), encoding: .utf8) { return text }
        let shiftJis = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)))
        if let text = String(data: data, encoding: shiftJis) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

// The preview: a read-only text view, with any notices above it.
public enum PreviewView {
    @MainActor
    public static func make(_ content: PreviewContent) -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        for notice in content.notices {
            let label = NSTextField(wrappingLabelWithString: notice)
            label.textColor = content.refused ? .systemRed : .secondaryLabelColor
            label.font = .systemFont(ofSize: content.refused ? 14 : 12, weight: content.refused ? .semibold : .regular)
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
            label.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            ])
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if content.refused { stack.addArrangedSubview(NSView()); return container }

        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = true
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 14, height: 14)
            textView.isAutomaticLinkDetectionEnabled = false
            textView.textStorage?.setAttributedString(content.text)
        }
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return container
    }
}
