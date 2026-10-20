import Foundation
import FlectKit

public struct EncoderChoice: Equatable {
    public let name: String
    public let hardware: HardwareEncoder

    public var isHardware: Bool { hardware != .none }

    public var isHevc: Bool { name.hasPrefix("hevc") || name == "libx265" }
}

public enum Encoders {
    private static let lock = NSLock()
    private static var probed: Set<String>?
    private static var hardwareUnusable = false

    public static var installed: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let probed { return probed }
        let found = probe()
        probed = found
        return found
    }

    public static func has(_ name: String) -> Bool { installed.contains(name) }

    public static func disableHardware() {
        lock.lock()
        hardwareUnusable = true
        lock.unlock()
    }

    private static var hardwareDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hardwareUnusable
    }

    public static func cpuFallback(_ encoder: EncoderChoice) -> EncoderChoice? {
        guard encoder.isHardware else { return nil }
        let codec: VideoCodecChoice
        switch encoder.name.split(separator: "_").first ?? "" {
        case "hevc": codec = .h265
        case "av1": codec = .av1
        case "vp9": codec = .vp9
        default: codec = .h264
        }
        let software = software(codec, allowHardware: false)
        return software == encoder ? nil : software
    }

    public static func forContainer(_ ext: String, _ settings: VideoSettings) -> EncoderChoice {
        switch ext {
        case ".webm":
            return preferred(Containers.codec(for: .webM, settings.codec), settings.hardware)
        case ".avi":
            return EncoderChoice(name: "mpeg4", hardware: .none)
        case ".mov":
            return preferred(Containers.suitsMov(settings.codec) ? settings.codec : .h264, settings.hardware)
        default:
            return preferred(settings.codec, settings.hardware)
        }
    }

    public static func preferred(_ codec: VideoCodecChoice, _ hardware: HardwareEncoder) -> EncoderChoice {
        if hardware == .videoToolbox, !hardwareDisabled, !Acceleration.knownUnusable(hardware),
           let accelerated = hardwareName(codec), has(accelerated) {
            return EncoderChoice(name: accelerated, hardware: .videoToolbox)
        }
        return software(codec, allowHardware: !hardwareDisabled)
    }

    private static func software(_ codec: VideoCodecChoice, allowHardware: Bool) -> EncoderChoice {
        let name: String
        switch codec {
        case .h265: name = "libx265"
        case .vp9: name = "libvpx-vp9"
        case .av1: name = has("libsvtav1") ? "libsvtav1" : "libaom-av1"
        case .h264: name = "libx264"
        }
        if has(name) { return EncoderChoice(name: name, hardware: .none) }

        if codec == .h265, allowHardware, has("hevc_videotoolbox") {
            return EncoderChoice(name: "hevc_videotoolbox", hardware: .videoToolbox)
        }
        return EncoderChoice(name: "libx264", hardware: .none)
    }

    private static func hardwareName(_ codec: VideoCodecChoice) -> String? {
        switch codec {
        case .h264: return "h264_videotoolbox"
        case .h265: return "hevc_videotoolbox"
        default: return nil
        }
    }

    public static func quality(_ encoder: EncoderChoice, _ priority: EncodePriority) -> [String] {
        let common = ["-c:v", encoder.name]
        if encoder.hardware == .videoToolbox {
            return common + ["-q:v", level(priority, 55, 65, 75), "-allow_sw", "1"] + speedHint(priority)
        }
        switch encoder.name {
        case "libvpx-vp9":
            return common + ["-crf", level(priority, 36, 32, 28), "-b:v", "0"]
        case "libsvtav1", "libaom-av1":
            return common + ["-crf", level(priority, 38, 34, 30), "-preset", av1Preset(priority)]
        case "mpeg4":
            return common + ["-qscale:v", level(priority, 5, 3, 2)]
        default:
            return common + ["-crf", level(priority, 24, 20, 18), "-preset", softwarePreset(priority)]
        }
    }

    public static func bitrate(_ encoder: EncoderChoice, kbps: Int, _ priority: EncodePriority) -> [String] {
        let common = ["-c:v", encoder.name, "-b:v", "\(kbps)k"]
        if encoder.hardware == .videoToolbox {
            return common + ["-allow_sw", "1"] + speedHint(priority)
        }
        switch encoder.name {
        case "libsvtav1", "libaom-av1": return common + ["-preset", av1Preset(priority)]
        case "libvpx-vp9": return common + ["-deadline", priority == .speed ? "realtime" : "good"]
        case "mpeg4": return common
        default: return common + ["-preset", softwarePreset(priority)]
        }
    }

    public static func pixelFormat(_ encoder: EncoderChoice) -> [String] {
        encoder.isHardware ? [] : ["-pix_fmt", "yuv420p"]
    }

    public static func tags(_ encoder: EncoderChoice, extension ext: String) -> [String] {
        encoder.isHevc && [".mp4", ".mov", ".m4v"].contains(ext) ? ["-tag:v", "hvc1"] : []
    }

    private static func speedHint(_ priority: EncodePriority) -> [String] {
        priority == .speed ? ["-prio_speed", "1"] : []
    }

    private static func softwarePreset(_ priority: EncodePriority) -> String {
        switch priority {
        case .speed: return "veryfast"
        case .quality: return "slow"
        case .balanced: return "medium"
        }
    }

    private static func av1Preset(_ priority: EncodePriority) -> String {
        switch priority {
        case .speed: return "10"
        case .quality: return "6"
        case .balanced: return "8"
        }
    }

    private static func level(_ priority: EncodePriority, _ speed: Int, _ balanced: Int, _ quality: Int) -> String {
        switch priority {
        case .speed: return String(speed)
        case .quality: return String(quality)
        case .balanced: return String(balanced)
        }
    }

    private static func probe() -> Set<String> {
        guard let ffmpeg = Tools.ffmpegIfPresent else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var names = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 8, let first = trimmed.first, "VAS".contains(first) else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 { names.insert(String(parts[1])) }
        }
        return names
    }
}

public enum Acceleration {
    private static let fileName = "hardware.json"

    private struct Probe: Codable {
        var fingerprint: String
        var working: [String]
    }

    public static func usable() -> [HardwareEncoder] {
        let current = fingerprint()
        if let cached = Store.read(Probe.self, from: fileName, defaults: Probe(fingerprint: "", working: [])),
           cached.fingerprint == current {
            return decode(cached.working)
        }
        var working: [String] = []
        if Encoders.has("h264_videotoolbox"), canEncode("h264_videotoolbox") {
            working.append(HardwareEncoder.videoToolbox.rawValue)
        }
        Store.write(Probe(fingerprint: current, working: working), to: fileName)
        return decode(working)
    }

    public static func knownUnusable(_ hardware: HardwareEncoder) -> Bool {
        if hardware == .none { return false }
        guard let cached = Store.read(Probe.self, from: fileName, defaults: Probe(fingerprint: "", working: [])),
              cached.fingerprint == fingerprint() else { return false }
        return !cached.working.contains(hardware.rawValue)
    }

    private static func decode(_ working: [String]) -> [HardwareEncoder] {
        working.compactMap(HardwareEncoder.init(rawValue:))
    }

    private static func canEncode(_ encoder: String) -> Bool {
        guard let ffmpeg = Tools.ffmpegIfPresent else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                             "-f", "lavfi", "-i", "color=c=black:s=320x240:d=1",
                             "-c:v", encoder, "-f", "null", "-"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }

        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func fingerprint() -> String {
        var parts: [String] = []
        if let ffmpeg = Tools.ffmpegIfPresent,
           let attributes = try? FileManager.default.attributesOfItem(atPath: ffmpeg) {
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("ffmpeg:\(size)@\(Int64(modified))")
        } else {
            parts.append("ffmpeg:none")
        }
        parts.append(machineModel())
        parts.append(ProcessInfo.processInfo.operatingSystemVersionString)
        return parts.joined(separator: "|")
    }

    private static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

public enum Containers {
    public static func resolve(_ video: VideoSettings) -> VideoContainer {
        if video.container == .auto { return video.codec == .vp9 ? .webM : .mp4 }
        return video.container
    }

    public static func suitsWebM(_ codec: VideoCodecChoice) -> Bool { codec == .vp9 || codec == .av1 }

    public static func suitsMov(_ codec: VideoCodecChoice) -> Bool { codec == .h264 || codec == .h265 }

    public static func codec(for container: VideoContainer, _ codec: VideoCodecChoice) -> VideoCodecChoice {
        container == .webM && !suitsWebM(codec) ? .vp9 : codec
    }

    public static func fileExtension(_ container: VideoContainer) -> String {
        switch container {
        case .mkv: return ".mkv"
        case .webM: return ".webm"
        default: return ".mp4"
        }
    }

    public static func canCopyVideo(_ source: MediaInfo, _ container: VideoContainer) -> Bool {
        if container == .webM { return ["vp8", "vp9", "av1"].contains(source.videoCodec ?? "") }
        return source.videoCodec?.lowercased() == "h264"
    }

    public static func canCopyAudio(_ source: MediaInfo, _ container: VideoContainer) -> Bool {
        guard let codec = source.audioCodec else { return false }
        if container == .webM { return codec == "opus" || codec == "vorbis" }
        return codec.lowercased().hasPrefix("aac")
    }

    public static func alreadyIn(_ source: MediaInfo, _ container: VideoContainer) -> Bool {
        container == .mp4 ? source.isMp4Family : source.container.lowercased().contains("matroska")
    }
}

public enum EncodePolicy {
    private static let floor = 1
    private static let probeEvery = 10
    private static let fileName = "encoder.json"

    private struct Memory: Codable {
        var processors: Int
        var threads: Int
        var runs: Int
    }

    public static var usableProcessors: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }

    static func workloadCeiling(_ shortSide: Int) -> Int {
        switch shortSide {
        case ...0: return 8
        case ...720: return 6
        case ...1080: return 8
        case ...1440: return 12
        default: return 16
        }
    }

    public static func ladder(shortSide: Int) -> [Int] {
        let ceiling = min(workloadCeiling(shortSide), usableProcessors)
        let start = min(max(startingPoint(ceiling), floor), ceiling)

        var rungs: [Int] = []
        var threads = start
        while threads > floor {
            rungs.append(threads)
            threads /= 2
        }
        rungs.append(floor)
        return rungs
    }

    public static func recordSuccess(threads: Int) {
        let memory = load()
        Store.write(Memory(processors: usableProcessors, threads: threads, runs: memory.runs + 1), to: fileName)
    }

    private static func startingPoint(_ ceiling: Int) -> Int {
        let memory = load()
        if memory.threads <= 0 || memory.processors != usableProcessors { return ceiling }
        let probing = memory.runs > 0 && memory.runs % probeEvery == 0
        return probing ? min(ceiling, memory.threads * 2) : memory.threads
    }

    private static func load() -> Memory {
        Store.read(Memory.self, from: fileName, defaults: Memory(processors: 0, threads: 0, runs: 0))
            ?? Memory(processors: 0, threads: 0, runs: 0)
    }
}
