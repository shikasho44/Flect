import Foundation

public enum Branding {
    public static let name = "Flect"
    public static let bundleIdentifier = "io.github.shikasho44.flect"
    public static let finderIdentifier = bundleIdentifier + ".finder"
    public static let urlScheme = "flect"
    public static let defaultUpdateRepository = "shikasho44/Flect"

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public static var updateRepository: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "FlectUpdateRepository") as? String
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? defaultUpdateRepository
    }
}

public enum Locations {
    private static let homeVariable = "FLECT_HOME"

    public static var userHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var support: URL {
        if let override = ProcessInfo.processInfo.environment[homeVariable], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return userHome
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Branding.name, isDirectory: true)
    }
}
