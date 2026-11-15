import AppKit

// Colours source text for Quick Look. A small lexer per family is enough to tell comments, strings, numbers,
// keywords and markup apart; it never runs or loads anything.
public enum Highlighter {
    public enum Style {
        case plain, comment, string, number, keyword, key, tag, attribute, heading
    }

    struct Language {
        var lineComments: [String] = []
        var blockComments: [(String, String)] = []
        var quotes: [Character] = ["\"", "'"]
        var keywords: Set<String> = []
        var caseInsensitiveKeywords = false
        var markup = false
        var css = false
        var keyValue = false
        var json = false
    }

    private static let cFamily: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
        "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof",
        "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true",
        "false", "NULL", "nullptr", "class", "namespace", "public", "private", "protected", "template", "typename",
        "virtual", "override", "new", "delete", "this", "using", "try", "catch", "throw", "import", "include",
        "define", "ifdef", "ifndef", "endif", "pragma",
    ]
    private static let swift: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "protocol", "public", "static", "struct", "subscript",
        "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for",
        "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil",
        "rethrows", "super", "self", "Self", "throw", "throws", "true", "try", "async", "await", "actor", "some",
        "any", "lazy", "final", "override", "mutating", "weak", "unowned", "convenience", "required",
    ]
    private static let javaLike: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements",
        "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected",
        "public", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws",
        "try", "void", "volatile", "while", "true", "false", "null", "var", "val", "fun", "object", "when", "is",
        "in", "override", "data", "sealed", "companion", "string", "using", "namespace", "async", "await", "def",
        "lazy", "yield", "record", "get", "set", "let", "const", "foreach", "readonly", "struct", "base", "out",
    ]
    private static let javaScript: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in",
        "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
        "try", "typeof", "undefined", "var", "void", "while", "with", "yield", "interface", "type", "enum",
        "implements", "private", "public", "protected", "readonly", "as", "keyof", "declare", "namespace",
    ]
    private static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
        "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch",
        "type", "var", "true", "false", "nil", "iota",
    ]
    private static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn",
        "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
        "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    private static let php: Set<String> = [
        "abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare",
        "default", "do", "echo", "else", "elseif", "empty", "extends", "final", "finally", "fn", "for", "foreach",
        "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "list", "match",
        "namespace", "new", "or", "print", "private", "protected", "public", "require", "return", "static",
        "switch", "throw", "trait", "try", "unset", "use", "var", "while", "yield", "true", "false", "null",
    ]
    private static let python: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
        "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self", "match", "case",
    ]
    private static let ruby: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure",
        "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return",
        "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "puts",
    ]
    private static let shell: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function",
        "select", "return", "exit", "export", "local", "readonly", "set", "unset", "shift", "source", "echo",
        "true", "false", "param", "foreach", "rem", "goto", "call", "setlocal", "endlocal",
    ]
    private static let lua: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil",
        "not", "or", "repeat", "return", "then", "true", "until", "while",
    ]
    private static let sql: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop",
        "alter", "add", "index", "view", "join", "left", "right", "inner", "outer", "on", "as", "and", "or", "not",
        "null", "is", "in", "between", "like", "group", "by", "order", "having", "limit", "offset", "distinct",
        "union", "all", "primary", "key", "foreign", "references", "default", "case", "when", "then", "else", "end",
        "begin", "commit", "rollback", "exists", "with", "returning", "asc", "desc", "integer", "text", "varchar",
    ]

    static func language(for ext: String) -> Language {
        let c = Language(lineComments: ["//"], blockComments: [("/*", "*/")])
        switch ext.lowercased() {
        case "swift": return with(c, keywords: swift)
        case "c", "h", "cpp", "hpp", "cc", "hh", "cxx", "m", "mm": return with(c, keywords: cFamily)
        case "cs", "java", "kt", "kts", "scala", "dart", "gradle", "groovy": return with(c, keywords: javaLike)
        case "js", "mjs", "cjs", "jsx", "tsx": return with(c, quotes: ["\"", "'", "`"], keywords: javaScript)
        case "go": return with(c, quotes: ["\"", "'", "`"], keywords: go)
        case "rs": return with(c, keywords: rust)
        case "php": return Language(lineComments: ["//", "#"], blockComments: [("/*", "*/")], keywords: php)
        case "py", "pyw": return Language(lineComments: ["#"], keywords: python)
        case "rb": return Language(lineComments: ["#"], keywords: ruby)
        case "sh", "bash", "zsh", "fish", "command": return Language(lineComments: ["#"], keywords: shell)
        case "ps1", "psm1": return Language(lineComments: ["#"], blockComments: [("<#", "#>")], keywords: shell,
                                            caseInsensitiveKeywords: true)
        case "bat", "cmd": return Language(lineComments: ["::"], quotes: ["\""], keywords: shell, caseInsensitiveKeywords: true)
        case "lua": return Language(lineComments: ["--"], blockComments: [("--[[", "]]")], keywords: lua)
        case "sql": return Language(lineComments: ["--"], blockComments: [("/*", "*/")], quotes: ["'", "\""], keywords: sql,
                                    caseInsensitiveKeywords: true)
        case "json", "jsonc": return Language(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\""],
                                              keywords: ["true", "false", "null"], json: true)
        case "yaml", "yml": return Language(lineComments: ["#"], keywords: ["true", "false", "null", "yes", "no"], keyValue: true)
        case "toml", "ini", "cfg", "conf", "properties", "env":
            return Language(lineComments: ["#", ";"], keywords: ["true", "false"], keyValue: true)
        case "css", "scss", "less": return Language(lineComments: ext == "css" ? [] : ["//"], blockComments: [("/*", "*/")], css: true)
        case "html", "htm", "xhtml", "xml", "svg", "plist", "vue", "svelte", "xaml", "csproj":
            return Language(blockComments: [("<!--", "-->")], markup: true)
        default: return Language(quotes: [])
        }
    }

    private static func with(_ base: Language, quotes: [Character]? = nil, keywords: Set<String>) -> Language {
        var language = base
        if let quotes { language.quotes = quotes }
        language.keywords = keywords
        return language
    }

    public static func color(_ style: Style) -> NSColor {
        switch style {
        case .plain: return .labelColor
        case .comment: return .secondaryLabelColor
        case .string: return .systemRed
        case .number: return .systemPurple
        case .keyword: return .systemPink
        case .key: return .systemTeal
        case .tag: return .systemBlue
        case .attribute: return .systemOrange
        case .heading: return .systemBlue
        }
    }

    public static func font(size: CGFloat = 12, bold: Bool = false) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    // Spans to colour, as UTF-16 ranges into `text`.
    public static func spans(_ text: String, extension ext: String) -> [(NSRange, Style)] {
        let language = language(for: ext)
        let units = Array(text.utf16)
        if language.markup { return markupSpans(units, language) }
        return codeSpans(units, language)
    }

    public static func highlight(_ text: String, extension ext: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font(), .foregroundColor: color(.plain)])
        for (range, style) in spans(text, extension: ext) where style != .plain {
            result.addAttribute(.foregroundColor, value: color(style), range: range)
            if style == .keyword || style == .tag || style == .heading { result.addAttribute(.font, value: font(bold: true), range: range) }
        }
        return result
    }

    // MARK: Lexers

    private static func matches(_ units: [UInt16], _ index: Int, _ probe: [UInt16]) -> Bool {
        guard index + probe.count <= units.count else { return false }
        for offset in 0..<probe.count where units[index + offset] != probe[offset] { return false }
        return true
    }

    private static func isIdentifier(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
            || unit == 0x24 || unit == 0x40 || unit == 0x3F || unit >= 0x80
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    private static func lineEnd(_ units: [UInt16], from index: Int) -> Int {
        var end = index
        while end < units.count, units[end] != 0x0A { end += 1 }
        return end
    }

    private static func skipString(_ units: [UInt16], from index: Int, quote: UInt16) -> Int {
        let triple = index + 2 < units.count && units[index + 1] == quote && units[index + 2] == quote && quote != 0x60
        var cursor = index + (triple ? 3 : 1)
        while cursor < units.count {
            let unit = units[cursor]
            if unit == 0x5C { cursor += 2; continue }
            if triple {
                if unit == quote, cursor + 2 < units.count, units[cursor + 1] == quote, units[cursor + 2] == quote { return cursor + 3 }
            } else {
                if unit == quote { return cursor + 1 }
                if unit == 0x0A, quote != 0x60 { return cursor }
            }
            cursor += 1
        }
        return units.count
    }

    private static func codeSpans(_ units: [UInt16], _ language: Language) -> [(NSRange, Style)] {
        var spans: [(NSRange, Style)] = []
        let quotes = Set(language.quotes.compactMap { $0.utf16.first })
        let lines = language.lineComments.map { Array($0.utf16) }
        let blocks = language.blockComments.map { (Array($0.0.utf16), Array($0.1.utf16)) }
        var index = 0
        var lineStart = true
        while index < units.count {
            let unit = units[index]
            if unit == 0x0A { index += 1; lineStart = true; continue }
            if unit == 0x20 || unit == 0x09 || unit == 0x0D { index += 1; continue }

            if let block = blocks.first(where: { matches(units, index, $0.0) }) {
                var end = index + block.0.count
                while end < units.count, !matches(units, end, block.1) { end += 1 }
                end = min(units.count, end + block.1.count)
                spans.append((NSRange(location: index, length: end - index), .comment))
                index = end
                lineStart = false
                continue
            }
            if lines.contains(where: { matches(units, index, $0) })
                || (language.keyValue && lineStart && (unit == 0x23 || unit == 0x3B)) {
                let end = lineEnd(units, from: index)
                spans.append((NSRange(location: index, length: end - index), .comment))
                index = end
                continue
            }
            if language.keyValue, lineStart, unit == 0x5B {
                let end = lineEnd(units, from: index)
                spans.append((NSRange(location: index, length: end - index), .heading))
                index = end
                continue
            }
            if quotes.contains(unit) {
                let end = skipString(units, from: index, quote: unit)
                var style = Style.string
                if language.json {
                    var after = end
                    while after < units.count, units[after] == 0x20 || units[after] == 0x09 { after += 1 }
                    if after < units.count, units[after] == 0x3A { style = .key }
                }
                spans.append((NSRange(location: index, length: end - index), style))
                index = end
                lineStart = false
                continue
            }
            if isDigit(unit) || (unit == 0x2D && index + 1 < units.count && isDigit(units[index + 1]) && language.json) {
                var end = index + 1
                while end < units.count, isIdentifier(units[end]) || units[end] == 0x2E { end += 1 }
                spans.append((NSRange(location: index, length: end - index), .number))
                index = end
                lineStart = false
                continue
            }
            if isIdentifier(unit) || (language.css && unit == 0x2D) {
                var end = index + 1
                while end < units.count, isIdentifier(units[end]) || (language.css || language.keyValue) && units[end] == 0x2D
                    || language.keyValue && units[end] == 0x2E { end += 1 }
                let word = String(utf16CodeUnits: Array(units[index..<end]), count: end - index)
                var after = end
                while after < units.count, units[after] == 0x20 || units[after] == 0x09 { after += 1 }
                let next: UInt16 = after < units.count ? units[after] : 0
                let style: Style
                if language.keyValue, lineStart, next == 0x3A || next == 0x3D {
                    style = .key
                } else if language.css, next == 0x3A, !word.hasPrefix("@") {
                    style = .key
                } else if language.css, word.hasPrefix("@") {
                    style = .keyword
                } else if language.keywords.contains(language.caseInsensitiveKeywords ? word.lowercased() : word) {
                    style = .keyword
                } else {
                    style = .plain
                }
                if style != .plain { spans.append((NSRange(location: index, length: end - index), style)) }
                index = end
                lineStart = false
                continue
            }
            index += 1
            lineStart = false
        }
        return spans
    }

    private static func markupSpans(_ units: [UInt16], _ language: Language) -> [(NSRange, Style)] {
        var spans: [(NSRange, Style)] = []
        let open = Array("<!--".utf16)
        let close = Array("-->".utf16)
        var index = 0
        while index < units.count {
            if matches(units, index, open) {
                var end = index + 4
                while end < units.count, !matches(units, end, close) { end += 1 }
                end = min(units.count, end + 3)
                spans.append((NSRange(location: index, length: end - index), .comment))
                index = end
                continue
            }
            guard units[index] == 0x3C else { index += 1; continue }
            // A tag: its name, then attribute names and quoted values until '>'.
            var cursor = index + 1
            while cursor < units.count, units[cursor] == 0x2F || units[cursor] == 0x3F || units[cursor] == 0x21 { cursor += 1 }
            var nameEnd = cursor
            while nameEnd < units.count, isIdentifier(units[nameEnd]) || units[nameEnd] == 0x2D || units[nameEnd] == 0x3A
                || units[nameEnd] == 0x2E { nameEnd += 1 }
            if nameEnd == cursor { index += 1; continue }
            spans.append((NSRange(location: index, length: nameEnd - index), .tag))
            cursor = nameEnd
            while cursor < units.count, units[cursor] != 0x3E {
                let unit = units[cursor]
                if unit == 0x22 || unit == 0x27 {
                    var end = cursor + 1
                    while end < units.count, units[end] != unit { end += 1 }
                    end = min(units.count, end + 1)
                    spans.append((NSRange(location: cursor, length: end - cursor), .string))
                    cursor = end
                } else if isIdentifier(unit) {
                    var end = cursor + 1
                    while end < units.count, isIdentifier(units[end]) || units[end] == 0x2D || units[end] == 0x3A { end += 1 }
                    spans.append((NSRange(location: cursor, length: end - cursor), .attribute))
                    cursor = end
                } else {
                    cursor += 1
                }
            }
            if cursor < units.count { spans.append((NSRange(location: cursor, length: 1), .tag)) }
            index = cursor + 1
        }
        return spans
    }
}
