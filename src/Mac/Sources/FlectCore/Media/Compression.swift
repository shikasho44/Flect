import Foundation
import FlectKit

enum Bitrate {
    static let minVideoKbps = 80

    static func safeTarget(_ targetBytes: Int64) -> Int64 {
        let reserve = max(64 * 1024, Int64((Double(targetBytes) * 0.003).rounded(.up)))
        return max(1, targetBytes - reserve)
    }

    static func videoKbps(_ safeTargetBytes: Int64, duration: Double, audioKbps: Int) -> Int {
        let totalKbps = Double(safeTargetBytes) * 8 / duration / 1000
        let muxingReserve = max(8, totalKbps * 0.01)
        return Int((totalKbps - Double(audioKbps) - muxingReserve).rounded(.down))
    }

    static func bitsPerPixelFrame(_ videoKbps: Int, width: Int, height: Int, fps: Double) -> Double {
        Double(videoKbps) * 1000 / (Double(width) * Double(height) * fps)
    }

    static func defaultAudioKbps(_ channels: Int) -> Int {
        channels <= 1 ? 64 : channels <= 2 ? 128 : 160
    }
}

enum AudioMode { case none, copy, encode }

enum InitialStrategy { case remux, audioOnly, videoEncode }

struct AudioPlan {
    var mode: AudioMode
    var effectiveKbps: Int
    var encodeKbps: Int
}

struct EncodingProfile {
    var width: Int
    var height: Int
    var fps: Double
    var videoKbps: Int
    var audioKbps: Int
}

struct Plan {
    var safeTargetBytes: Int64
    var strategy: InitialStrategy
    var profile: EncodingProfile
    var audio: AudioPlan
    var source: MediaInfo
    var container: VideoContainer

    var maxFullAttempts: Int { 2 }
    var videoCopyable: Bool { Containers.canCopyVideo(source, container) }
    var fileExtension: String { Containers.fileExtension(container) }
}

enum Planner {
    static func build(_ source: MediaInfo, targetBytes: Int64, container: VideoContainer) -> Plan {
        let safeTarget = Bitrate.safeTarget(targetBytes)
        let audio = buildAudio(source, container)

        let aimBytes = Int64(Double(safeTarget) * 0.93)
        var videoKbps = Bitrate.videoKbps(aimBytes, duration: max(0.1, source.duration), audioKbps: audio.effectiveKbps)

        if source.videoBitrate > 0 {
            let sourceKbps = Int(source.videoBitrate / 1000)
            if videoKbps > sourceKbps {
                videoKbps = max(Bitrate.minVideoKbps, Int(Double(sourceKbps) * 0.98))
            }
        }
        if videoKbps < Bitrate.minVideoKbps { videoKbps = Bitrate.minVideoKbps }

        return Plan(safeTargetBytes: safeTarget,
                    strategy: chooseStrategy(source, audio, container),
                    profile: Profile.build(source, videoKbps: videoKbps, audioKbps: audio.effectiveKbps),
                    audio: audio,
                    source: source,
                    container: container)
    }

    private static func buildAudio(_ source: MediaInfo, _ container: VideoContainer) -> AudioPlan {
        if source.audioTrackCount == 0 { return AudioPlan(mode: .none, effectiveKbps: 0, encodeKbps: 0) }

        let requested = Bitrate.defaultAudioKbps(source.audioChannels)
        let sourceKbps = source.audioBitrate > 0 ? Int((Double(source.audioBitrate) / 1000).rounded()) : nil

        if Containers.canCopyAudio(source, container), let kbps = sourceKbps, kbps <= requested {
            return AudioPlan(mode: .copy, effectiveKbps: kbps, encodeKbps: requested)
        }
        return AudioPlan(mode: .encode, effectiveKbps: requested, encodeKbps: requested)
    }

    private static func chooseStrategy(_ source: MediaInfo, _ audio: AudioPlan, _ container: VideoContainer) -> InitialStrategy {
        let videoCopyable = Containers.canCopyVideo(source, container)
        let hasRemovableTracks = source.audioTrackCount > 1 || source.subtitleTrackCount > 0
        let remuxable = videoCopyable
            && (source.audioTrackCount == 0 || Containers.canCopyAudio(source, container))
            && (!Containers.alreadyIn(source, container) || hasRemovableTracks)

        if remuxable { return .remux }
        if videoCopyable, audio.mode == .encode { return .audioOnly }
        return .videoEncode
    }
}

enum Profile {
    private static let bppSampleTest = 0.03

    private struct Candidate: Hashable {
        var width: Int
        var height: Int
        var fps: Double
    }

    static func makeEven(_ value: Int) -> Int { max(2, value / 2 * 2) }

    static func build(_ source: MediaInfo, videoKbps: Int, audioKbps: Int) -> EncodingProfile {
        let candidates = self.candidates(source)
        for candidate in candidates
        where Bitrate.bitsPerPixelFrame(videoKbps, width: candidate.width, height: candidate.height, fps: candidate.fps) >= bppSampleTest {
            return profile(candidate, videoKbps, audioKbps)
        }
        return profile(candidates[candidates.count - 1], videoKbps, audioKbps)
    }

    private static func profile(_ candidate: Candidate, _ videoKbps: Int, _ audioKbps: Int) -> EncodingProfile {
        EncodingProfile(width: candidate.width, height: candidate.height, fps: candidate.fps,
                        videoKbps: videoKbps, audioKbps: audioKbps)
    }

    private static func candidates(_ source: MediaInfo) -> [Candidate] {
        let width = makeEven(source.width)
        let height = makeEven(source.height)
        let fps = source.frameRate > 0 ? source.frameRate : 30

        func clamp(_ value: Double) -> Double { min(value, fps) }

        let raw = [
            Candidate(width: width, height: height, fps: fps),
            Candidate(width: width, height: height, fps: clamp(30)),
            Candidate(width: width, height: height, fps: clamp(24)),
            scaledToShortSide(width, height, 1080, clamp(24)),
            scaledToShortSide(width, height, 720, clamp(24)),
            scaledToShortSide(width, height, 480, clamp(24)),
        ]

        var seen = Set<String>()
        var unique: [Candidate] = []
        for candidate in raw {
            if candidate.width > width || candidate.height > height { continue }
            if candidate.fps > fps + 0.001 { continue }
            let key = "\(candidate.width)x\(candidate.height)@\(String(format: "%.3f", candidate.fps))"
            if seen.insert(key).inserted { unique.append(candidate) }
        }
        return unique
    }

    private static func scaledToShortSide(_ sourceWidth: Int, _ sourceHeight: Int, _ target: Int, _ fps: Double) -> Candidate {
        if sourceWidth >= sourceHeight {
            let scaledHeight = makeEven(min(target, sourceHeight))
            let scaledWidth = makeEven(Int((Double(scaledHeight) * Double(sourceWidth) / Double(sourceHeight)).rounded()))
            return Candidate(width: scaledWidth, height: scaledHeight, fps: fps)
        }
        let narrowWidth = makeEven(min(target, sourceWidth))
        let tallHeight = makeEven(Int((Double(narrowWidth) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
        return Candidate(width: narrowWidth, height: tallHeight, fps: fps)
    }
}

enum CompressionCommand {
    private static let trackMaps = ["-map", "0:v:0", "-map", "0:a:0?"]
    private static let fastStart = ["-movflags", "+faststart"]

    private static func containerFlags(_ container: VideoContainer) -> [String] {
        container == .mp4 ? fastStart : []
    }

    static func remux(_ input: String, _ output: String, _ plan: Plan) -> [String] {
        Ffmpeg.preamble + ["-i", input] + trackMaps + ["-c", "copy"] + containerFlags(plan.container) + [output]
    }

    static func audioOnly(_ input: String, _ output: String, _ plan: Plan) -> [String] {
        var arguments: [String] = Ffmpeg.preamble + ["-i", input] + trackMaps
        arguments += ["-c:v", "copy"] + audioCodec(plan)
        arguments += containerFlags(plan.container) + [output]
        return arguments
    }

    static func encoder(_ plan: Plan) -> EncoderChoice {
        let video = Settings.current.video
        return Encoders.preferred(Containers.codec(for: plan.container, video.codec), video.hardware)
    }

    static func singlePass(_ input: String, _ output: String, _ plan: Plan, _ encoder: EncoderChoice,
                           videoKbps: Int, threads: Int) -> [String] {
        let video = Settings.current.video
        var arguments: [String] = Ffmpeg.preamble + ["-i", input] + trackMaps
        arguments += videoFilter(plan)
        arguments += ["-threads", String(threads)]
        arguments += Encoders.bitrate(encoder, kbps: videoKbps, video.priority)
        arguments += Encoders.pixelFormat(encoder)
        arguments += Encoders.tags(encoder, extension: plan.fileExtension)
        arguments += audioCodec(plan)
        arguments += containerFlags(plan.container)
        arguments.append(output)
        return arguments
    }

    static func audioOnlySource(_ input: String, _ output: String, audioKbps: Int) -> [String] {
        Ffmpeg.preamble + ["-i", input, "-vn", "-c:a", "aac", "-b:a", "\(audioKbps)k"] + fastStart + [output]
    }

    private static func audioCodec(_ plan: Plan) -> [String] {
        switch plan.audio.mode {
        case .none: return ["-an"]
        case .copy: return ["-c:a", "copy"]
        case .encode:
            return ["-c:a", plan.container == .webM ? "libopus" : "aac", "-b:a", "\(plan.audio.encodeKbps)k"]
        }
    }

    private static func videoFilter(_ plan: Plan) -> [String] {
        let profile = plan.profile
        let sourceWidth = Profile.makeEven(plan.source.width)
        let sourceHeight = Profile.makeEven(plan.source.height)
        let sourceFps = plan.source.frameRate > 0 ? plan.source.frameRate : 30

        var parts: [String] = []
        if profile.width != sourceWidth || profile.height != sourceHeight {
            parts.append("scale=\(profile.width):\(profile.height)")
            parts.append("setsar=1")
        }
        if abs(profile.fps - sourceFps) > 0.01 {
            parts.append("fps=" + Formatting.number((profile.fps * 1000).rounded() / 1000))
        }
        return parts.isEmpty ? [] : ["-vf", parts.joined(separator: ",")]
    }
}

struct CompressionOutcome {
    var path: String
    var bytes: Int64
    var targetReached: Bool
}

struct CompressionPipeline {
    let plan: Plan
    let progress: TaskProgress

    func run(_ input: String, _ scratch: ScratchDirectory) async throws -> CompressionOutcome {
        let duration = plan.source.duration

        if plan.strategy == .remux {
            let remux = scratch.path(for: "remux" + plan.fileExtension)
            if let bytes = try await tryStage(CompressionCommand.remux(input, remux, plan), remux, "Repackaging", duration) {
                return CompressionOutcome(path: remux, bytes: bytes, targetReached: true)
            }
        }

        if plan.videoCopyable, plan.audio.mode == .encode {
            let audioOnly = scratch.path(for: "audio" + plan.fileExtension)
            if let bytes = try await tryStage(CompressionCommand.audioOnly(input, audioOnly, plan), audioOnly,
                                              "Compressing audio", duration) {
                return CompressionOutcome(path: audioOnly, bytes: bytes, targetReached: true)
            }
        }

        var videoKbps = plan.profile.videoKbps
        var best: String?
        var bestBytes = Int64.max

        for attempt in 1...plan.maxFullAttempts {
            try Task.checkCancellation()

            let encode = scratch.path(for: "encode-\(attempt)" + plan.fileExtension)
            let label = "Encoding \(plan.profile.width)x\(plan.profile.height)@\(Int(plan.profile.fps.rounded()))fps · \(videoKbps)kbps"
            let kbps = videoKbps

            try await Ffmpeg.runEncode(CompressionCommand.encoder(plan), progress, label: label, duration: duration,
                                       shortSide: min(plan.profile.width, plan.profile.height)) { encoder, threads in
                CompressionCommand.singlePass(input, encode, plan, encoder, videoKbps: kbps, threads: threads)
            }

            let size = FileSystem.size(of: encode) ?? 0
            if size <= plan.safeTargetBytes { return CompressionOutcome(path: encode, bytes: size, targetReached: true) }

            if size < bestBytes {
                if let best { OutputPath.safeDelete(best) }
                best = encode
                bestBytes = size
            } else {
                OutputPath.safeDelete(encode)
            }

            if attempt < plan.maxFullAttempts {
                videoKbps = max(10, Int(Double(videoKbps) * (Double(plan.safeTargetBytes) / Double(size)) * 0.97))
                progress.status("Adjusting to \(videoKbps)kbps")
            }
        }

        if let best { return CompressionOutcome(path: best, bytes: bestBytes, targetReached: false) }
        throw FlectError("Every compression attempt failed for this file.")
    }

    func runAudioOnlySource(_ input: String, _ scratch: ScratchDirectory) async throws -> CompressionOutcome {
        let duration = plan.source.duration
        let budgetKbps = Int64(Double(plan.safeTargetBytes) * 8 / max(0.1, duration) / 1000)
        let audioKbps = Int(min(max(budgetKbps - 4, 8), 320))

        let output = scratch.path(for: "audio-source.m4a")
        try await Ffmpeg.run(CompressionCommand.audioOnlySource(input, output, audioKbps: audioKbps), progress,
                             label: "Encoding audio · \(audioKbps)kbps", duration: duration)
        let size = FileSystem.size(of: output) ?? 0
        return CompressionOutcome(path: output, bytes: size, targetReached: size <= plan.safeTargetBytes)
    }

    private func tryStage(_ arguments: [String], _ output: String, _ label: String, _ duration: Double) async throws -> Int64? {
        progress.status(label)
        do {
            try await Ffmpeg.run(arguments, progress, label: label, duration: duration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            OutputPath.safeDelete(output)
            return nil
        }

        guard let size = FileSystem.size(of: output) else { return nil }
        if size <= plan.safeTargetBytes { return size }
        OutputPath.safeDelete(output)
        return nil
    }
}
