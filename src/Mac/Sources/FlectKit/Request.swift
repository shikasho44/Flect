import Foundation
import Security

public struct Request {
    public let domain: String
    public let action: String
    public let paths: [String]
    private let parameters: [String: String]

    public var id: String { "\(domain).\(action)" }

    public subscript(key: String) -> String? { parameters[key.lowercased()] }

    public init?(verb: String, paths: [String]) {
        let cleaned = paths.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        guard !verb.trimmingCharacters(in: .whitespaces).isEmpty, !cleaned.isEmpty else { return nil }

        let query = verb.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let name = query[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard name.count == 2 else { return nil }

        var parameters: [String: String] = [:]
        if query.count == 2 {
            for pair in query[1].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                parameters[String(parts[0]).lowercased()] = parts.count == 2 ? String(parts[1]) : ""
            }
        }

        self.domain = String(name[0])
        self.action = String(name[1])
        self.parameters = parameters
        self.paths = cleaned
    }

    public init?(arguments: [String]) {
        var verb: String?
        var input: String?
        var index = 0
        while index + 1 < arguments.count {
            switch arguments[index] {
            case "--task": verb = arguments[index + 1]
            case "--input": input = arguments[index + 1]
            default: break
            }
            index += 2
        }
        guard let verb, let input else { return nil }
        self.init(verb: verb, paths: Request.readSelection(input))
    }

    private static func readSelection(_ listFile: String) -> [String] {
        defer { try? FileManager.default.removeItem(atPath: listFile) }
        guard let text = try? String(contentsOfFile: listFile, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespaces)) }
            .filter { !$0.isEmpty }
    }
}

public enum Handoff {
    public static let host = "run"
    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

    public static var tokenFile: URL { Locations.support.appendingPathComponent("handoff.key") }

    public static func url(verb: String, paths: [String], token: String?) -> URL? {
        var query = "task=" + encode(verb)
        if let token { query += "&token=" + encode(token) }
        for path in paths { query += "&path=" + encode(path) }
        return URL(string: "\(Branding.urlScheme)://\(host)?\(query)")
    }

    public static func parse(_ url: URL) -> (verb: String, paths: [String], token: String?)? {
        guard url.scheme?.lowercased() == Branding.urlScheme, url.host == host,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return nil }

        var verb: String?
        var token: String?
        var paths: [String] = []
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let value = String(parts[1]).removingPercentEncoding else { continue }
            switch parts[0] {
            case "task": verb = value
            case "token": token = value
            case "path": paths.append(value)
            default: break
            }
        }
        guard let verb, !paths.isEmpty else { return nil }
        return (verb, paths, token)
    }

    public static func readToken() -> String? {
        guard let text = try? String(contentsOf: tokenFile, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    public static func ensureToken() -> String? {
        if let existing = readToken() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: Locations.support, withIntermediateDirectories: true)
            try token.write(to: tokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            return token
        } catch {
            return nil
        }
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
