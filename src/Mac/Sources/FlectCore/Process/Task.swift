import Foundation
import FlectKit

public protocol TaskProgress: AnyObject {
    func status(_ text: String)
    func step(_ done: Int, _ total: Int)
    func indeterminate()
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

public struct FlectError: LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

public func describe(_ error: Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription { return description }
    return (error as NSError).localizedDescription
}

func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

open class FlectTask {
    public let request: Request

    public init(_ request: Request) { self.request = request }

    open var title: String { Branding.name }

    open var showsProgress: Bool { true }

    open func configure(_ ui: Interaction) async -> Bool { true }

    open func run(_ progress: TaskProgress) async throws {}

    open var summary: String? { nil }

    open func present(_ ui: Interaction) async {}
}

open class BatchTask: FlectTask {
    open func process(_ path: String, _ progress: TaskProgress) async throws {}

    override open func run(_ progress: TaskProgress) async throws {
        let paths = request.paths
        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            progress.step(index, paths.count)
            progress.status(fileName(path))

            do {
                try await process(path, progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress.error("\(fileName(path)) - \(describe(error))")
            }
        }
        progress.step(paths.count, paths.count)
    }

    func largestSelected() -> Int64 {
        request.paths.compactMap { FileSystem.size(of: $0) }.max() ?? 0
    }
}

public struct PixelTarget {
    public var width: Int
    public var height: Int
    public var keepAspect: Bool

    public init(width: Int, height: Int, keepAspect: Bool) {
        self.width = width
        self.height = height
        self.keepAspect = keepAspect
    }
}

public struct TrimRange {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

public struct RenamePlan {
    public var prefix: String
    public var name: String
    public var suffix: String
    public var numbered: Bool

    public init(prefix: String, name: String, suffix: String, numbered: Bool) {
        self.prefix = prefix
        self.name = name
        self.suffix = suffix
        self.numbered = numbered
    }
}

public protocol Interaction: AnyObject {
    func askPixels() async -> PixelTarget?
    func askTargetBytes(largest: Int64) async -> Int64?
    func askTrim(path: String, duration: Double) async -> TrimRange?
    func askThumbnail(path: String, duration: Double) async -> Double?
    func askRename(sampleExtension: String) async -> RenamePlan?
    func askDuplicates(_ groups: [[ScannedFile]]) async -> DuplicateMode?
    func askPdfOrder(_ paths: [String]) async -> [String]?
    func confirm(_ message: String) async -> Bool
    func reportError(_ message: String) async
    func showText(title: String, text: String) async
    func showAnalyze(_ report: AnalyzeReport) async
    func showPdfPreview(path: String) async
    func copyToClipboard(_ text: String) async -> Bool
}
