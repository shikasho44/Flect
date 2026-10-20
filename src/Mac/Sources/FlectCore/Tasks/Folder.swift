import Foundation
import FlectKit

final class FolderRemoveDuplicate: FlectTask {
    private var outcome: String?
    private var ui: Interaction?

    override var title: String { Loc.t("menu.folder.removeDuplicate") }
    override var summary: String? { outcome }

    override func configure(_ ui: Interaction) async -> Bool {
        self.ui = ui
        return true
    }

    override func run(_ progress: TaskProgress) async throws {
        let folder = Settings.current.folder
        progress.indeterminate()
        progress.status(Loc.t("msg.scanning"))

        let scan = try FileScanner.scan(request.paths, progress: progress, options: .from(folder))
        let groups = try FileScanner.findDuplicates(scan.files, progress: progress, settings: folder.duplicates)
        if groups.isEmpty {
            outcome = Loc.t("msg.noDuplicates")
            return
        }

        let mode: DuplicateMode?
        switch folder.duplicates.keep {
        case .oldest: mode = .keepOldest
        case .newest: mode = .keepNewest
        case .ask:
            if let argument = request["keep"] {
                mode = DuplicateMode(argument: argument)
            } else {
                mode = await ui?.askDuplicates(groups)
            }
        }
        guard let mode else { throw CancellationError() }

        let doomed = DuplicatePlan.toDelete(groups, mode: mode)
        if doomed.isEmpty {
            outcome = Loc.t("msg.nothingToRemove")
            return
        }

        let reclaimed = doomed.reduce(Int64(0)) { $0 + $1.size }
        let permanent = folder.deleteMethod == .permanent
        progress.indeterminate()
        progress.status(Loc.f(permanent ? "msg.deletingPermanently" : "msg.movingToRecycle", Loc.n("count.file", doomed.count)))

        try Recycler.delete(doomed.map(\.path), method: folder.deleteMethod)
        outcome = Loc.f(permanent ? "msg.deletedPermanently" : "msg.recycled", Loc.n("count.file", doomed.count),
                        Formatting.bytes(reclaimed))
    }
}

extension DuplicateMode {
    init(argument: String) {
        switch argument.lowercased() {
        case "newest": self = .keepNewest
        case "all": self = .deleteAll
        default: self = .keepOldest
        }
    }
}

final class FolderRemoveEmpty: FlectTask {
    private var outcome: String?
    private var ui: Interaction?

    override var title: String { Loc.t("menu.folder.removeEmpty") }
    override var summary: String? { outcome }

    override func configure(_ ui: Interaction) async -> Bool {
        self.ui = ui
        return true
    }

    override func run(_ progress: TaskProgress) async throws {
        let folder = Settings.current.folder
        progress.indeterminate()
        progress.status(Loc.t("msg.lookingForEmpty"))

        let scan = try FileScanner.scan(request.paths, progress: progress, options: .from(folder))
        if scan.emptyDirectories.isEmpty {
            outcome = Loc.t("msg.noEmpty")
            return
        }

        let targets = FileScanner.outermost(scan.emptyDirectories)
        let permanent = folder.deleteMethod == .permanent
        let counted = Loc.n("count.emptyFolder", scan.emptyDirectories.count)

        if request["confirm"] != "yes" {
            let message = Loc.f(permanent ? "msg.confirmEmptyPermanent" : "msg.confirmEmptyRecycle", counted, preview(targets))
            guard let ui, await ui.confirm(message) else { throw CancellationError() }
        }

        try Recycler.delete(targets, method: folder.deleteMethod)
        outcome = Loc.f(permanent ? "msg.emptyDeleted" : "msg.emptyRecycled", counted)
    }

    private func preview(_ directories: [String]) -> String {
        let shown = 12
        var lines = Array(directories.prefix(shown))
        if directories.count > shown { lines.append(Loc.f("msg.andMore", Formatting.count(directories.count - shown))) }
        return lines.joined(separator: "\n")
    }
}

final class FolderTree: FlectTask {
    private var output = ""

    override var title: String { Loc.t("menu.folder.tree") }

    override func run(_ progress: TaskProgress) async throws {
        progress.indeterminate()
        output = try TreeRenderer.render(request.paths, settings: Settings.current.folder.tree, progress: progress)
    }

    override func present(_ ui: Interaction) async {
        await ui.showText(title: title, text: output)
    }

    var text: String { output }
}

final class FolderRename: FlectTask {
    private var plan = RenamePlan(prefix: "", name: "", suffix: "", numbered: true)
    private var settings = RenameSettings()
    private var exclusions = ExclusionFilter.none
    private var preview: [String] = []
    private var renamed = 0

    override var title: String { Loc.t("menu.folder.rename") }

    override var summary: String? {
        settings.dryRun
            ? Loc.f("msg.renameDryRun", Loc.n("count.file", preview.count))
            : Loc.f("msg.renamed", Loc.n("count.file", renamed))
    }

    override func configure(_ ui: Interaction) async -> Bool {
        settings = Settings.current.folder.rename
        exclusions = .from(settings.exclusions)

        if request["prefix"] != nil || request["suffix"] != nil || request["name"] != nil {
            plan = RenamePlan(prefix: request["prefix"]?.removingPercentEncoding ?? "",
                              name: request["name"]?.removingPercentEncoding ?? "",
                              suffix: request["suffix"]?.removingPercentEncoding ?? "",
                              numbered: request["numbered"] != "0")
            let whole = plan.prefix + plan.name + plan.suffix
            return !whole.contains("/") && !whole.contains(":")
        }

        let sample = request.paths.lazy
            .filter(FileSystem.isDirectory)
            .flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
            .filter { !self.exclusions.excludesFile($0) && !FinderFiles.isSystem($0) }
            .map { ($0 as NSString).pathExtension }
            .first { !$0.isEmpty }

        guard let answer = await ui.askRename(sampleExtension: "." + (sample ?? "png")) else { return false }
        plan = answer
        return true
    }

    override func run(_ progress: TaskProgress) async throws {
        for (index, folder) in request.paths.enumerated() {
            try Task.checkCancellation()
            progress.step(index, request.paths.count)
            guard FileSystem.isDirectory(folder) else { continue }
            progress.status(folder)
            try rename(folder, progress)
        }
        progress.step(request.paths.count, request.paths.count)
    }

    override func present(_ ui: Interaction) async {
        guard settings.dryRun, !preview.isEmpty else { return }
        await ui.showText(title: Loc.t("msg.renameDryRunTitle"), text: preview.joined(separator: "\n"))
    }

    private func rename(_ folder: String, _ progress: TaskProgress) throws {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { name in
            let path = (folder as NSString).appendingPathComponent(name)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return false }
            return !name.hasPrefix(".") && !FinderFiles.isSystem(name) && !exclusions.excludesFile(name)
        }

        var groups: [String: [String]] = [:]
        var order: [String] = []
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            if groups[ext] == nil { order.append(ext) }
            groups[ext, default: []].append(name)
        }

        for ext in order {
            let files = groups[ext]!.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let highest = settings.startNumber + files.count - 1
            let width = settings.digitCount > 0 ? settings.digitCount : max(1, String(highest).count)

            var taken = Set<String>()
            var steps: [(source: String, target: String)] = []
            for (index, file) in files.enumerated() {
                let middle = plan.numbered
                    ? String(settings.startNumber + index).leftPadded(width, with: "0")
                    : plan.name
                let stem = plan.prefix + middle + plan.suffix
                let original = (file as NSString).pathExtension
                let extensionText = original.isEmpty ? "" : "." + original

                var name = stem + extensionText
                var number = 2
                while !taken.insert(name.lowercased()).inserted {
                    name = "\(stem) (\(number))\(extensionText)"
                    number += 1
                }
                steps.append(((folder as NSString).appendingPathComponent(file), (folder as NSString).appendingPathComponent(name)))
            }

            if settings.dryRun {
                preview += steps.map { "\(($0.source as NSString).lastPathComponent)  ->  \(($0.target as NSString).lastPathComponent)" }
                continue
            }
            try apply(steps, progress)
        }
    }

    private func apply(_ steps: [(source: String, target: String)], _ progress: TaskProgress) throws {
        var staged: [(scratch: String, target: String, original: String)] = []
        for step in steps {
            if Task.isCancelled {
                for item in staged { try? FileManager.default.moveItem(atPath: item.scratch, toPath: item.original) }
                throw CancellationError()
            }
            if step.source == step.target { continue }
            let scratch = OutputPath.scratch(beside: step.target, extension: (step.source as NSString).pathExtension)
            do {
                try FileManager.default.moveItem(atPath: step.source, toPath: scratch)
                staged.append((scratch, step.target, step.source))
            } catch {
                progress.error("\((step.source as NSString).lastPathComponent) - \(describe(error))")
            }
        }

        for item in staged {
            do {
                try FileManager.default.moveItem(atPath: item.scratch, toPath: item.target)
                renamed += 1
            } catch {
                progress.error("\((item.target as NSString).lastPathComponent) - \(describe(error))")
                if (try? FileManager.default.moveItem(atPath: item.scratch, toPath: item.original)) == nil {
                    progress.error("Left behind as \((item.scratch as NSString).lastPathComponent)")
                }
            }
        }
    }
}

final class FolderAnalyze: FlectTask {
    private(set) var report: AnalyzeReport?

    override var title: String { Loc.t("menu.folder.analyze") }

    override func run(_ progress: TaskProgress) async throws {
        let folder = Settings.current.folder
        let started = Date()
        progress.indeterminate()
        progress.status(Loc.t("msg.scanning"))

        let scan = try FileScanner.scan(request.paths, progress: progress, options: .from(folder, extra: folder.analyze.exclusions))
        let duplicates = try FileScanner.findDuplicates(scan.files, progress: progress, settings: folder.duplicates)
        report = AnalyzeReport.build(request.paths, scan, duplicates, elapsed: Date().timeIntervalSince(started))
    }

    override func present(_ ui: Interaction) async {
        if let report { await ui.showAnalyze(report) }
    }
}

final class FolderCompress: BatchTask {
    override var title: String { Loc.t("menu.folder.compress") }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        let format = Settings.current.folder.archive.compressFormat
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = "." + Archive.fileExtension(format)

        progress.indeterminate()
        progress.status(Loc.f("label.compress", name))

        let scratch = try ScratchDirectory(beside: path)
        defer { scratch.dispose() }
        let staged = scratch.path(for: name + ext)

        let warnings = try await Archive.create(staged, from: name, in: parent, format: format)
        try FileManager.default.moveItem(atPath: staged, toPath: OutputPath.derive(path, extension: ext))
        Archive.report(warnings, name: name, progress: progress)
    }
}

final class ArchiveExtract: BatchTask {
    override var title: String { Loc.t("menu.archive.extract") }

    override func process(_ path: String, _ progress: TaskProgress) async throws {
        progress.indeterminate()
        progress.status(Loc.f("label.extracting", fileName(path)))

        let destination = OutputPath.deriveDirectory(path, stem: Archive.stem(path))
        let warnings = try await Archive.extract(path, into: destination)
        Archive.report(warnings, name: fileName(path), progress: progress)
    }
}

extension String {
    func leftPadded(_ width: Int, with pad: Character) -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
