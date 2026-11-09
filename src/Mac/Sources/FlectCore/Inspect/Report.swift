import Foundation
import FlectKit

// File › Analyze, ported from src/App/Inspect. A report is the alerts, an overview and one section per detector.

public struct FileFact: Equatable {
    public let label: String
    public let value: String
    public let key: String?

    public init(_ label: String, _ value: String, key: String? = nil) {
        self.label = label
        self.value = value
        self.key = key
    }
}

public struct FileSection: Equatable {
    public let title: String
    public let rows: [FileFact]
}

public struct FileReport: Equatable {
    public let path: String
    public let alerts: [String]
    public let overview: [FileFact]
    public let sections: [FileSection]
}

public struct ProbeResult {
    public var kind: String?
    public var executable = false
    public var sections: [FileSection] = []

    public init(kind: String? = nil, executable: Bool = false, sections: [FileSection] = []) {
        self.kind = kind
        self.executable = executable
        self.sections = sections
    }
}

public final class FactBag {
    public private(set) var rows: [FileFact] = []

    public init() {}

    public func add(_ key: String, _ value: String?) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rows.append(FileFact(Loc.t(key), value.trimmingCharacters(in: .whitespacesAndNewlines), key: key))
    }

    public func addRaw(_ label: String, _ value: String?) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rows.append(FileFact(label, value.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public func section(_ titleKey: String) -> FileSection? {
        rows.isEmpty ? nil : FileSection(title: Loc.t(titleKey), rows: rows)
    }

    // One-section result, the common shape of a detector's answer.
    public func result(_ titleKey: String, kind: String? = nil, executable: Bool = false) -> ProbeResult {
        ProbeResult(kind: kind, executable: executable, sections: section(titleKey).map { [$0] } ?? [])
    }
}
