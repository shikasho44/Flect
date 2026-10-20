import AVFoundation
import Foundation
import Speech
import FlectKit

struct Cue {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleWriter {
    static func render(_ cues: [Cue], as output: SubtitleOutput) -> String {
        var text = output == .vtt ? "WEBVTT\n\n" : ""
        for (index, cue) in cues.enumerated() {
            switch output {
            case .txt:
                text += cue.text + "\n"
            case .srt:
                text += "\(index + 1)\n\(timestamp(cue.start, srt: true)) --> \(timestamp(cue.end, srt: true))\n"
                text += cue.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            case .vtt:
                text += "\(timestamp(cue.start, srt: false)) --> \(timestamp(cue.end, srt: false))\n"
                text += cue.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            }
        }
        return text
    }

    static func timestamp(_ seconds: Double, srt: Bool) -> String {
        var total = max(0, Int((seconds * 1000).rounded()))
        let hours = total / 3_600_000
        total %= 3_600_000
        let minutes = total / 60_000
        total %= 60_000
        let secs = total / 1000
        let millis = total % 1000
        return String(format: srt ? "%02d:%02d:%02d,%03d" : "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    static func fileExtension(_ output: SubtitleOutput) -> String {
        switch output {
        case .vtt: return ".vtt"
        case .txt: return ".txt"
        case .srt: return ".srt"
        }
    }
}

final class MediaSubtitles: FlectTask {
    private var settings = SubtitlesSettings()

    override var title: String { Loc.t(request.domain == "audio" ? "menu.audio.subtitles" : "menu.video.subtitles") }

    override func configure(_ ui: Interaction) async -> Bool {
        settings = Settings.current.video.subtitles
        return true
    }

    override func run(_ progress: TaskProgress) async throws {
        let ext = SubtitleWriter.fileExtension(settings.output)
        var jobs: [(input: String, output: String, wav: String, duration: Double)] = []
        defer { jobs.forEach { OutputPath.safeDelete($0.wav) } }

        for (index, path) in request.paths.enumerated() {
            try Task.checkCancellation()
            progress.step(index, request.paths.count)
            progress.status(fileName(path))

            let info: MediaInfo
            do {
                info = try await Media.read(path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress.error("\(fileName(path)) - \(describe(error))")
                continue
            }
            if !info.hasAudio {
                progress.error("\(fileName(path)) - \(Loc.t("msg.noAudioTrack"))")
                continue
            }
            if info.duration <= 0 {
                progress.error("\(fileName(path)) - \(Loc.t("msg.noDuration"))")
                continue
            }

            let output = OutputPath.derive(path, extension: ext, avoiding: Set(jobs.map(\.output)))
            let wav = OutputPath.scratch(beside: output, extension: ".wav")
            do {
                try await Ffmpeg.run(Ffmpeg.preamble + ["-i", path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav],
                                     progress, label: Loc.t("label.extractingAudio"), duration: info.duration)
            } catch is CancellationError {
                OutputPath.safeDelete(wav)
                throw CancellationError()
            } catch {
                OutputPath.safeDelete(wav)
                progress.error("\(fileName(path)) - \(describe(error))")
                continue
            }
            jobs.append((path, output, wav, info.duration))
        }
        if jobs.isEmpty { return }

        if settings.engine == .whisper {
            try await Whisper.transcribe(jobs.map { ($0.input, $0.output, $0.wav) }, settings: settings, progress: progress)
            return
        }

        for (index, job) in jobs.enumerated() {
            try Task.checkCancellation()
            progress.step(index, jobs.count)
            progress.status(fileName(job.input))
            do {
                let cues = try await AppleSpeech.transcribe(job.wav, duration: job.duration, language: settings.language) { fraction in
                    progress.status("\(fileName(job.input)) - \(Formatting.wholePercent(fraction))")
                }
                if cues.isEmpty {
                    progress.warn(Loc.f("msg.noTextFound", fileName(job.input)))
                    continue
                }
                let text = SubtitleWriter.render(cues, as: settings.output)
                try await OutputPath.producing(job.output) {
                    try Data(text.utf8).write(to: URL(fileURLWithPath: job.output))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress.error("\(fileName(job.input)) - \(describe(error))")
            }
        }
        progress.step(jobs.count, jobs.count)
    }
}

enum AppleSpeech {
    private static let whisperLocales = [
        "ja": "ja-JP", "en": "en-US", "zh": "zh-CN", "ko": "ko-KR", "es": "es-ES", "fr": "fr-FR", "de": "de-DE",
        "it": "it-IT", "pt": "pt-BR", "ru": "ru-RU", "ar": "ar-SA", "th": "th-TH", "vi": "vi-VN",
    ]

    static func locale(for language: String) -> Locale {
        if language.isEmpty {
            let preferred = Locale.preferredLanguages.first ?? "en-US"
            return Locale(identifier: preferred)
        }
        return Locale(identifier: whisperLocales[language] ?? language)
    }

    static func transcribe(_ wav: String, duration: Double, language: String,
                           onProgress: @escaping (Double) -> Void) async throws -> [Cue] {
        let locale = locale(for: language)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            return try await modern(wav, locale: locale, duration: duration, onProgress: onProgress)
        }
        #endif
        return try await legacy(wav, locale: locale)
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func modern(_ wav: String, locale requested: Locale, duration: Double,
                               onProgress: @escaping (Double) -> Void) async throws -> [Cue] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw FlectError(Loc.f("msg.subtitlesLocale", requested.identifier))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress(0)
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav))

        let collector = Task { () -> [Cue] in
            var cues: [Cue] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                if !text.isEmpty { cues.append(Cue(start: start.isFinite ? start : 0, end: end.isFinite ? end : start, text: text)) }
                if duration > 0, end.isFinite { onProgress(min(1, end / duration)) }
            }
            return cues
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }
    #endif

    private static func legacy(_ wav: String, locale: Locale) async throws -> [Cue] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw FlectError(Loc.t("msg.speechDenied")) }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw FlectError(Loc.f("msg.subtitlesLocale", locale.identifier))
        }
        guard recognizer.isAvailable else { throw FlectError(Loc.t("msg.speechUnavailable")) }

        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: wav))
        request.shouldReportPartialResults = false
        guard recognizer.supportsOnDeviceRecognition else { throw FlectError(Loc.f("msg.subtitlesLocale", locale.identifier)) }
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        let holder = RecognitionHolder()
        let transcription: SFTranscription = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            var finished = false
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription)
                }
            }
            }
        } onCancel: {
            holder.task?.cancel()
        }
        try Task.checkCancellation()

        let joiner = ["ja", "zh", "th"].contains(locale.language.languageCode?.identifier ?? "") ? "" : " "
        var cues: [Cue] = []
        var current: Cue?
        for segment in transcription.segments {
            let start = segment.timestamp
            let end = segment.timestamp + segment.duration
            if var cue = current, start - cue.end < 0.8, end - cue.start < 6, cue.text.count < 40 {
                cue.text += joiner + segment.substring
                cue.end = end
                current = cue
            } else {
                if let cue = current { cues.append(cue) }
                current = Cue(start: start, end: end, text: segment.substring)
            }
            if let last = segment.substring.last, "。．.！!？?".contains(last), let cue = current {
                cues.append(cue)
                current = nil
            }
        }
        if let cue = current { cues.append(cue) }
        return cues
    }
}

private final class RecognitionHolder: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
}

enum Whisper {
    private static var environment: URL { Locations.support.appendingPathComponent("env") }
    private static var python: String { environment.appendingPathComponent("bin/python3").path }
    private static var models: String { Locations.support.appendingPathComponent("models").path }
    private static let utf8 = ["PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"]

    static func transcribe(_ items: [(input: String, output: String, wav: String)], settings: SubtitlesSettings,
                           progress: TaskProgress) async throws {
        try await ensureEnvironment(progress)
        guard let script = Tools.resource("subtitles.py") else { throw FlectError(Loc.f("msg.toolMissing", "subtitles.py")) }

        let manifest = (OutputPath.temporaryDirectory() as NSString).appendingPathComponent("subtitles-\(UUID().uuidString).json")
        defer { OutputPath.safeDelete(manifest) }
        let payload = items.map { ["input": $0.wav, "output": $0.output] }
        try JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: manifest))

        progress.status(Loc.t("msg.subtitlesTranscribing"))
        let positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.wav, $0.offset) })
        let lock = NSLock()
        var outcomes: [String: (ok: Bool, empty: Bool, error: String?)] = [:]

        let arguments = [script, "--model", modelName(settings.model), "--device", "cpu",
                         "--language", settings.language.isEmpty ? "auto" : settings.language,
                         "--format", settings.output.rawValue.lowercased(), "--manifest", manifest]
        try FileManager.default.createDirectory(atPath: models, withIntermediateDirectories: true)

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(python, arguments, environment: utf8.merging(["HF_HOME": models]) { $1 },
                                                 background: true) { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let notice = object["notice"] as? String {
                    progress.info(notice)
                    return
                }
                let wav = object["input"] as? String ?? ""
                let position = positions[wav] ?? -1
                let name = fileName(position >= 0 ? items[position].input : wav)
                if let fraction = object["progress"] as? Double {
                    progress.status("\(name) - \(Formatting.wholePercent(fraction))")
                } else if object["status"] != nil {
                    if position >= 0 { progress.step(position, items.count) }
                    progress.status(name)
                } else {
                    let ok = object["ok"] as? Bool ?? false
                    lock.lock()
                    outcomes[wav] = (ok, ok && (object["empty"] as? Bool ?? false), ok ? nil : object["error"] as? String)
                    lock.unlock()
                    if position >= 0 { progress.step(position + 1, items.count) }
                }
            }
        } catch is CancellationError {
            let done = lock.withLock { outcomes }
            for item in items where done[item.wav]?.ok != true { OutputPath.safeDelete(item.output) }
            throw CancellationError()
        }

        for line in result.standardError.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            progress.info(line)
        }
        if result.exitCode != 0 {
            let detail = result.standardError.split(separator: "\n").prefix(5).joined(separator: "\n")
            throw FlectError(detail.isEmpty ? "subtitles process exited with code \(result.exitCode)" : detail)
        }

        for item in items {
            let outcome = outcomes[item.wav] ?? (FileSystem.exists(item.output), false, nil)
            if outcome.empty {
                OutputPath.safeDelete(item.output)
                progress.warn(Loc.f("msg.noTextFound", fileName(item.input)))
            } else if !outcome.ok || !FileSystem.exists(item.output) {
                OutputPath.safeDelete(item.output)
                progress.error("\(fileName(item.input)) - \(outcome.error ?? Loc.t("msg.subtitlesFailed"))")
            }
        }
    }

    private static func ensureEnvironment(_ progress: TaskProgress) async throws {
        try FileManager.default.createDirectory(atPath: models, withIntermediateDirectories: true)
        if FileManager.default.isExecutableFile(atPath: python) {
            if try await canImport() { return }
            progress.status(Loc.t("msg.subtitlesUpdating"))
        } else {
            progress.status(Loc.t("msg.subtitlesSettingUp"))
        }

        guard let system = systemPython() else { throw FlectError(Loc.t("msg.subtitlesNoPython")) }
        if !FileManager.default.isExecutableFile(atPath: python) {
            progress.info(Loc.t("msg.subtitlesCreatingEnv"))
            let created = try await ProcessRunner.run(system, ["-m", "venv", environment.path], environment: utf8)
            if created.exitCode != 0 || !FileManager.default.isExecutableFile(atPath: python) {
                throw FlectError("\(Loc.t("msg.bgVenvFailed")): \(created.standardError)")
            }
        }

        progress.info(Loc.t("msg.bgUpgradingPip"))
        _ = try await ProcessRunner.run(python, ["-m", "pip", "install", "--upgrade", "pip", "--quiet", "--disable-pip-version-check"],
                                        environment: utf8)
        progress.info(Loc.t("msg.subtitlesInstallingDeps"))
        let install = try await ProcessRunner.run(python, ["-m", "pip", "install", "--quiet", "--disable-pip-version-check",
                                                           "faster-whisper"], environment: utf8)
        if install.exitCode != 0 { throw FlectError("\(Loc.t("msg.subtitlesInstallFailed")): \(install.standardError)") }
        if try await !canImport() { throw FlectError(Loc.t("msg.subtitlesInstallFailed")) }
        progress.info(Loc.t("msg.subtitlesReady"))
    }

    private static func canImport() async throws -> Bool {
        let result = try await ProcessRunner.run(python, ["-c", "import faster_whisper; print('ok')"], environment: utf8)
        return result.exitCode == 0 && result.standardOutput.contains("ok")
    }

    static func systemPython() -> String? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        let frameworks = "/Library/Frameworks/Python.framework/Versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: frameworks) {
            candidates += versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                .map { "\(frameworks)/\($0)/bin/python3" }
        }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate)
            process.arguments = ["-c", "import sys; print(sys.version_info >= (3, 10))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if process.terminationStatus == 0, output.contains("True") { return candidate }
        }
        return nil
    }

    private static func modelName(_ model: SubtitleModel) -> String {
        switch model {
        case .tiny: return "tiny"
        case .base: return "base"
        case .medium: return "medium"
        case .largeV3: return "large-v3"
        case .turbo: return "turbo"
        case .small: return "small"
        }
    }
}
