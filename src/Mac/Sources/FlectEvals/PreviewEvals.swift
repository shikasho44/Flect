import AppKit
import FlectKit
import FlectPreviewKit

enum PreviewEvals {
    private static func styles(_ text: String, _ ext: String) -> [(String, Highlighter.Style)] {
        let units = text as NSString
        return Highlighter.spans(text, extension: ext).map { (units.substring(with: $0.0), $0.1) }
    }

    private static func write(_ name: String, _ data: Data) throws -> URL {
        let folder = try Paths.folder("preview-\(name)")
        let url = URL(fileURLWithPath: Paths.join(folder, name))
        try data.write(to: url)
        return url
    }

    static func register(_ suite: Suite) {
        suite.test("Preview colours code: keywords, strings, comments and numbers") {
            let found = styles("let x = \"hi\" // note\nreturn 42", "swift")
            try expect(found.contains { $0 == ("let", .keyword) } && found.contains { $0 == ("return", .keyword) }, "\(found)")
            try expect(found.contains { $0 == ("\"hi\"", .string) } && found.contains { $0 == ("// note", .comment) }, "\(found)")
            try expect(found.contains { $0 == ("42", .number) }, "\(found)")
            let python = styles("def f():\n    return \"\"\"doc\n# not a comment\"\"\"  # real", "py")
            try expect(python.contains { $0.0.hasPrefix("\"\"\"doc") && $0.1 == .string } && python.contains { $0 == ("# real", .comment) },
                       "\(python)")
        }

        suite.test("Preview tells JSON keys from values and marks up HTML tags") {
            let json = styles(#"{"name": "Flect", "count": 3, "ok": true}"#, "json")
            try expect(json.contains { $0 == ("\"name\"", .key) } && json.contains { $0 == ("\"Flect\"", .string) }, "\(json)")
            try expect(json.contains { $0 == ("3", .number) } && json.contains { $0 == ("true", .keyword) }, "\(json)")
            let html = styles(#"<!-- c --><a href="x.html">link</a>"#, "html")
            try expect(html.contains { $0 == ("<!-- c -->", .comment) } && html.contains { $0 == ("<a", .tag) }, "\(html)")
            try expect(html.contains { $0 == ("href", .attribute) } && html.contains { $0 == ("\"x.html\"", .string) }, "\(html)")
            let ini = styles("[server]\nport = 80 ; comment", "ini")
            try expect(ini.contains { $0 == ("[server]", .heading) } && ini.contains { $0 == ("port", .key) }, "\(ini)")
        }

        suite.test("Preview renders Markdown and keeps only web links") {
            let text = MarkdownRenderer.render("# Title\n\nSome **bold** and `code`, [web](https://example.com) and [file](file:///etc/passwd).\n\n- one\n- two\n")
            let plain = text.string
            try expect(plain.contains("Title") && plain.contains("•\tone") && plain.contains("•\ttwo"), plain)
            let title = text.attribute(.font, at: (plain as NSString).range(of: "Title").location, effectiveRange: nil) as? NSFont
            try expect((title?.pointSize ?? 0) >= 20, "heading size \(title?.pointSize ?? 0)")
            let web = text.attribute(.link, at: (plain as NSString).range(of: "web").location, effectiveRange: nil)
            let file = text.attribute(.link, at: (plain as NSString).range(of: "file").location, effectiveRange: nil)
            try expect(web != nil && file == nil, "web \(String(describing: web)) file \(String(describing: file))")
            try expect(!plain.contains("**") && !plain.contains("`"), plain)
        }

        suite.test("Preview refuses a program dressed as code and shows HTML only as source") {
            Loc.use(.english)
            let disguised = try write("setup.py", InspectCoreEvals.portableExecutable())
            let refused = try PreviewBuilder.build(disguised)
            try expect(refused.refused && refused.text.length == 0 && refused.notices.first?.contains("PE") == true, "\(refused.notices)")
            let page = try write("page.html", Data("<script>alert(1)</script><img src=\"https://example.com/x.png\">".utf8))
            let html = try PreviewBuilder.build(page)
            try expect(!html.refused && html.text.string.contains("<script>alert(1)</script>"), html.text.string)
            try expect(html.notices.contains { $0.contains("source") }, "\(html.notices)")
            let empty = try PreviewBuilder.build(try write("empty.swift", Data()))
            try expect(!empty.refused && empty.text.length == 0, "\(empty.notices)")
        }

        suite.test("Preview reads UTF-16 and Shift_JIS, and stops at the size limit") {
            let utf16 = try write("u16.txt.json", Data([0xFF, 0xFE]) + "{\"日本\": 1}".data(using: .utf16LittleEndian)!)
            try expect(try PreviewBuilder.build(utf16).text.string.contains("日本"), "utf-16")
            let sjis = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)))
            let japanese = try write("memo.py", "# こんにちは\nprint(1)\n".data(using: sjis)!)
            try expect(try PreviewBuilder.build(japanese).text.string.contains("こんにちは"), "shift_jis")
            let line = String(repeating: "let a = 1 // filler\n", count: PreviewBuilder.limit / 20 + 1000)
            let large = try PreviewBuilder.build(try write("large.swift", Data(line.utf8)))
            try expect(large.notices.count == 1 && large.text.length <= PreviewBuilder.limit, "\(large.notices) \(large.text.length)")
        }

        suite.test("Preview colours a 2 MB one-line file quickly") {
            let minified = String(repeating: "var a=\"x\";function f(b){return b+1}/*c*/", count: 50_000)
            let started = Date()
            let result = Highlighter.highlight(minified, extension: "js")
            let elapsed = Date().timeIntervalSince(started)
            try expect(result.length == (minified as NSString).length && elapsed < 5, String(format: "%.2fs", elapsed))
        }

        suite.test("Preview survives unclosed strings, comments and tags in every language") {
            let pieces = ["\"", "'", "`", "\"\"\"", "/*", "*/", "//", "#", "<!--", "-->", "<", ">", "=", ":", "[", "\\",
                          "\n", " ", "a", "1", "-", "@", "日本", "😀", "\u{301}", "<#", "--[[", "::", ";", "{", "}"]
            let extensions = ["swift", "c", "cs", "js", "go", "rs", "php", "py", "rb", "sh", "ps1", "bat", "lua", "sql",
                              "json", "yaml", "toml", "css", "scss", "html", "xml", "md", "unknown"]
            var generator = SystemRandomNumberGenerator()
            for ext in extensions {
                for _ in 0..<40 {
                    let text = (0..<Int.random(in: 0...200, using: &generator))
                        .map { _ in pieces.randomElement(using: &generator)! }.joined()
                    let result = ext == "md" ? MarkdownRenderer.render(text) : Highlighter.highlight(text, extension: ext)
                    if ext != "md" { try expect(result.length == (text as NSString).length, "length changed for \(ext)") }
                }
            }
        }

        suite.test("Preview claims every code type the app declares") {
            var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("src/Mac/Resources").path) {
                guard directory.pathComponents.count > 1 else { throw Skip(reason: "resources not found") }
                directory.deleteLastPathComponent()
            }
            let resources = directory.appendingPathComponent("src/Mac/Resources")
            func plist(_ path: String) throws -> [String: Any] {
                try PropertyListSerialization.propertyList(from: Data(contentsOf: resources.appendingPathComponent(path)),
                                                           format: nil) as? [String: Any] ?? [:]
            }
            let app = try plist("App/Info.plist")
            let preview = try plist("Preview/Info.plist")
            let declared = (app["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
            let attributes = (preview["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
            let claimed = Set(attributes?["QLSupportedContentTypes"] as? [String] ?? [])
            try expect(!declared.isEmpty && declared.allSatisfy(claimed.contains), "unclaimed: \(declared.filter { !claimed.contains($0) })")
            try expect(!claimed.contains("public.plain-text") && !claimed.contains("com.adobe.pdf"), "claims types macOS handles itself")
        }
    }
}
