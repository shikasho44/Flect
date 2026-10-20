import Foundation

public struct RGBColor: Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let lime = RGBColor(red: 0, green: 255, blue: 0)
}

public enum ColorText {
    public static func parse(_ text: String?, fallback: RGBColor) -> RGBColor {
        guard var value = text?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 8 { value = String(value.dropFirst(2)) }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return fallback }
        return RGBColor(red: UInt8((rgb >> 16) & 0xFF), green: UInt8((rgb >> 8) & 0xFF), blue: UInt8(rgb & 0xFF))
    }

    public static func format(_ color: RGBColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }

    public static func forFfmpeg(_ text: String?) -> String {
        "0x" + format(parse(text, fallback: .black)).dropFirst()
    }
}
