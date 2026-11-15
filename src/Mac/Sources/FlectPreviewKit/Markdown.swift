import AppKit

// Markdown to styled text with Foundation's parser. Images are not fetched (their alt text stays), and only
// web and mail links stay clickable.
public enum MarkdownRenderer {
    public static func render(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: body(), .foregroundColor: NSColor.labelColor])
        }

        let output = NSMutableAttributedString()
        var lastBlock: Int?
        var lastItem: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            if let lastBlock, block != lastBlock { output.append(NSAttributedString(string: "\n")) }

            var font = body()
            var color = NSColor.labelColor
            var background: NSColor?
            var indent: CGFloat = 0
            var prefix = ""
            var spacing: CGFloat = 8
            for component in components {
                switch component.kind {
                case .header(let level):
                    let sizes: [CGFloat] = [24, 20, 17, 15, 14, 13]
                    font = .systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .bold)
                    spacing = 12
                case .codeBlock:
                    font = Highlighter.font()
                    background = .quaternaryLabelColor
                    indent += 12
                    spacing = 0
                case .blockQuote:
                    color = .secondaryLabelColor
                    indent += 16
                case .listItem(let ordinal):
                    indent += 20
                    if component.identity != lastItem, block != lastBlock {
                        let ordered = components.contains { if case .orderedList = $0.kind { return true } else { return false } }
                        prefix = ordered ? "\(ordinal).\t" : "•\t"
                        lastItem = component.identity
                    }
                case .thematicBreak:
                    color = .separatorColor
                case .tableHeaderRow:
                    font = .systemFont(ofSize: font.pointSize, weight: .semibold)
                default:
                    break
                }
            }
            if components.contains(where: { if case .tableCell = $0.kind { return true } else { return false } }), block != lastBlock,
               lastBlock != nil, output.string.hasSuffix("\n") {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
                output.append(NSAttributedString(string: "\t"))
            }

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) { font = Highlighter.font(size: font.pointSize - 1); background = .quaternaryLabelColor }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)),
                                  size: font.pointSize) ?? font
                }
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = prefix.isEmpty ? indent : max(0, indent - 20)
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            paragraph.paragraphSpacing = spacing
            paragraph.lineSpacing = 2

            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let background { attributes[.backgroundColor] = background }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
            }

            var text = String(parsed[run.range].characters)
            if components.contains(where: { if case .thematicBreak = $0.kind { return true } else { return false } }) {
                text = String(repeating: "─", count: 40)
            }
            if !prefix.isEmpty {
                output.append(NSAttributedString(string: prefix, attributes: [.font: body(), .foregroundColor: NSColor.labelColor,
                                                                              .paragraphStyle: paragraph]))
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
            lastBlock = block
        }
        return output
    }

    private static func body() -> NSFont { .systemFont(ofSize: 13) }
}
