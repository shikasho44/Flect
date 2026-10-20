import Foundation

public enum Strings {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .japanese: return japanese.merging(macJapanese) { _, mac in mac }
        case .chineseSimplified: return chinese.merging(macChinese) { _, mac in mac }
        default: return english.merging(macEnglish) { _, mac in mac }
        }
    }

    static let fallback = table(for: .english)

    public static func missingTranslations() -> [String] {
        let english = Set(table(for: .english).keys).filter { !$0.hasSuffix(".one") }
        return [(AppLanguage.japanese, "ja"), (.chineseSimplified, "zh")].flatMap { language, tag in
            english.subtracting(table(for: language).keys).sorted().map { "\(tag):\($0)" }
        }
    }
}

public enum Loc {
    private static let lock = NSLock()
    private static var table = Strings.fallback
    public private(set) static var current = AppLanguage.english

    public static func use(_ language: AppLanguage) {
        let resolved = resolve(language)
        let chosen = Strings.table(for: resolved)
        lock.lock()
        current = resolved
        table = chosen
        lock.unlock()
    }

    public static func resolve(_ language: AppLanguage) -> AppLanguage {
        if language != .system { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("ja") { return .japanese }
        if preferred.hasPrefix("zh") { return .chineseSimplified }
        return .english
    }

    public static var localeIdentifier: String {
        switch current {
        case .japanese: return "ja"
        case .chineseSimplified: return "zh-Hans"
        default: return "en"
        }
    }

    public static func t(_ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return table[key] ?? Strings.fallback[key] ?? key
    }

    public static func f(_ key: String, _ arguments: Any...) -> String {
        format(t(key), arguments)
    }

    public static func n(_ key: String, _ count: Int) -> String {
        lock.lock()
        let singular = count == 1 ? table[key + ".one"] : nil
        lock.unlock()
        return format(singular ?? t(key), [Formatting.count(count)])
    }

    static func format(_ template: String, _ arguments: [Any]) -> String {
        var text = template
        for (index, argument) in arguments.enumerated() {
            text = text.replacingOccurrences(of: "{\(index)}", with: String(describing: argument))
        }
        return text
    }
}
