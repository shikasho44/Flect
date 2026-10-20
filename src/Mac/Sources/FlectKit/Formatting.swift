import Foundation

public enum Formatting {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func bytes(_ value: Int64) -> String {
        if value < 1024 { return "\(value) B" }

        var scaled = Double(value)
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), scaled) + " " + units[unit]
    }

    public static func shortBytes(_ value: Int64) -> String {
        if value < 1024 { return "\(value) B" }

        var scaled = Double(value)
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        let digits = scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2
        var text = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), scaled)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text + " " + units[unit]
    }

    public static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func percent(_ fraction: Double) -> String {
        let digits = fraction >= 0.1 ? 1 : 2
        return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), fraction * 100) + "%"
    }

    public static func wholePercent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    public static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func timecode(_ seconds: Double) -> String {
        let clamped = seconds.isNaN || seconds < 0 ? 0 : seconds
        let totalMilliseconds = Int((clamped * 1000).rounded(.down))
        let tenths = (totalMilliseconds % 1000) / 100
        let totalSeconds = totalMilliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours >= 1 {
            return String(format: "%d:%02d:%02d.%d", hours, minutes, secs, tenths)
        }
        return String(format: "%d:%02d.%d", totalSeconds / 60, secs, tenths)
    }

    public static func parseTimecode(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 3 { return nil }

        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            total += value * pow(60, Double(parts.count - 1 - index))
        }
        return total.isFinite ? total : nil
    }

    public static func parseBytes(_ text: String) -> Int64? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        if trimmed.isEmpty { return nil }

        let suffixes: [(String, Double)] = [
            ("TB", 1_099_511_627_776), ("GB", 1_073_741_824), ("MB", 1_048_576), ("KB", 1024),
            ("T", 1_099_511_627_776), ("G", 1_073_741_824), ("M", 1_048_576), ("K", 1024), ("B", 1),
        ]
        var multiplier = 1.0
        for (suffix, scale) in suffixes where trimmed.uppercased().hasSuffix(suffix) {
            multiplier = scale
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        guard let value = Double(trimmed), value > 0 else { return nil }
        let product = value * multiplier
        guard product < Double(Int64.max) else { return nil }
        let bytes = Int64(product)
        return bytes > 0 ? bytes : nil
    }
}
