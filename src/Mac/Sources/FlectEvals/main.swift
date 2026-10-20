import Foundation
import FlectCore
import FlectKit

final class Suite {
    private struct Case {
        let name: String
        let category: String
        let body: () async throws -> Void
    }

    private var cases: [Case] = []
    private(set) var failures: [(String, String)] = []

    func test(_ name: String, category: String = "core", _ body: @escaping () async throws -> Void) {
        cases.append(Case(name: name, category: category, body: body))
    }

    func run(filters: [String], categories: Set<String>) async {
        var passed = 0
        var skipped: [(String, String)] = []
        let selected = cases.filter { item in
            categories.contains(item.category)
                && (filters.isEmpty || filters.contains { item.name.localizedCaseInsensitiveContains($0) })
        }

        for item in selected {
            let started = Date()
            do {
                try await item.body()
                passed += 1
                print(String(format: "PASS  %5.1fs  %@", Date().timeIntervalSince(started), item.name))
            } catch let skip as Skip {
                skipped.append((item.name, skip.reason))
                print("SKIP          \(item.name) - \(skip.reason)")
            } catch {
                failures.append((item.name, "\(error)"))
                print(String(format: "FAIL  %5.1fs  %@\n              %@", Date().timeIntervalSince(started), item.name, "\(error)"))
            }
        }

        print("\n\(passed) passed, \(failures.count) failed, \(skipped.count) skipped (\(selected.count) of \(cases.count) selected)")
        let others = Set(cases.map(\.category)).subtracting(categories).sorted()
        if !others.isEmpty { print("Not run: \(others.joined(separator: ", ")) - pass --\(others.joined(separator: " --")) to include") }
    }
}

func locateDependencies() -> String? {
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = directory.appendingPathComponent("dependencies/mac")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        directory.deleteLastPathComponent()
    }
    return nil
}

let arguments = Array(CommandLine.arguments.dropFirst())
var categories: Set<String> = ["core", "ai"]
for flag in arguments where flag.hasPrefix("--") { categories.insert(String(flag.dropFirst(2))) }
let filters = arguments.filter { !$0.hasPrefix("--") }

let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("FlectEvals-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
setenv("FLECT_HOME", (work as NSString).appendingPathComponent("home"), 1)
if ProcessInfo.processInfo.environment["FLECT_DEPS"] == nil, let dependencies = locateDependencies() {
    setenv("FLECT_DEPS", dependencies, 1)
}

Paths.root = (work as NSString).appendingPathComponent("cases")
Fixtures.masters = (work as NSString).appendingPathComponent("fixtures")
try? FileManager.default.createDirectory(atPath: Fixtures.masters, withIntermediateDirectories: true)
Loc.use(.english)

print("Flect evals - work folder \(work)")
print("ffmpeg: \(Tools.ffmpegIfPresent ?? "not found")\n")

let suite = Suite()
CoreEvals.register(suite)
ImageEvals.register(suite)
VideoEvals.register(suite)
FolderEvals.register(suite)
DocumentEvals.register(suite)
await suite.run(filters: filters, categories: categories)

if !categories.contains("keep") { try? FileManager.default.removeItem(atPath: work) }
exit(suite.failures.isEmpty ? 0 : 1)
