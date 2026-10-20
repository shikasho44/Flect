import Foundation
import FlectKit

public enum Tools {
    public static let tar = "/usr/bin/tar"

    private static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static var bundledDirectories: [URL] {
        var directories: [URL] = []
        let bundle = Bundle.main.bundleURL
        directories.append(bundle.appendingPathComponent("Contents/Helpers"))
        if let resources = Bundle.main.resourceURL { directories.append(resources.appendingPathComponent("deps")) }
        if let override = ProcessInfo.processInfo.environment["FLECT_DEPS"], !override.isEmpty {
            let root = URL(fileURLWithPath: override)
            directories.append(root.appendingPathComponent(architecture))
            directories.append(root)
        }
        return directories
    }

    public static func ffmpeg() throws -> String { try resolve("ffmpeg") }

    public static func ffprobe() throws -> String { try resolve("ffprobe") }

    public static var ffmpegIfPresent: String? { locate("ffmpeg") }

    public static func cfrJar() throws -> String {
        for directory in bundledDirectories {
            let candidate = directory.appendingPathComponent("cfr.jar").path
            if FileSystem.exists(candidate) { return candidate }
        }
        throw FlectError(Loc.f("msg.toolMissing", "cfr.jar"))
    }

    public static func resource(_ name: String) -> String? {
        for directory in bundledDirectories {
            let candidate = directory.appendingPathComponent(name).path
            if FileSystem.exists(candidate) { return candidate }
        }
        return nil
    }

    public static func java() throws -> String {
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"], !home.isEmpty {
            let candidate = (home as NSString).appendingPathComponent("bin/java")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let home = javaHome() {
            let candidate = (home as NSString).appendingPathComponent("bin/java")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        for directory in ["/opt/homebrew/opt/openjdk/bin", "/usr/local/opt/openjdk/bin"] {
            let candidate = (directory as NSString).appendingPathComponent("java")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw FlectError(Loc.t("msg.javaMissing"))
    }

    public static func javaHome() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let home = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return home.isEmpty ? nil : home
    }

    static func locate(_ name: String) -> String? {
        for directory in bundledDirectories {
            let candidate = directory.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in path + searchPath {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func resolve(_ name: String) throws -> String {
        if let found = locate(name) { return found }
        throw FlectError(Loc.f("msg.toolMissing", name))
    }
}
