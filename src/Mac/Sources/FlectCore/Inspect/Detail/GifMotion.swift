import Foundation

// Walks the GIF block structure without decoding pixels.
enum GifMotion {
    static let budget = 4 * 1024 * 1024

    struct Layout {
        var animated = false
        var interlaced: Bool?
        var comment = ""
    }

    static func isAnimated(_ path: String) -> Bool {
        guard let data = head(path) else { return false }
        return walk(data, untilFirstFrame: false).animated
    }

    // Interlace flag of the first frame and the comments written before it.
    static func firstFrame(_ data: [UInt8]) -> Layout { walk(data, untilFirstFrame: true) }

    static func head(_ path: String) -> [UInt8]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: budget) else { return nil }
        return [UInt8](data)
    }

    private static func walk(_ data: [UInt8], untilFirstFrame: Bool) -> Layout {
        var layout = Layout()
        guard data.count >= 13, data[0] == UInt8(ascii: "G"), data[1] == UInt8(ascii: "I"), data[2] == UInt8(ascii: "F")
        else { return layout }
        var cursor = 13
        guard skip(data, &cursor, colorTable(data[10])) else { return layout }

        var frames = 0
        while cursor < data.count {
            let block = data[cursor]
            cursor += 1
            if block == 0x3B { return layout }

            if block == 0x21 {
                guard cursor < data.count else { return layout }
                let label = data[cursor]
                cursor += 1
                if label == 0xFF {
                    guard cursor < data.count else { return layout }
                    let size = Int(data[cursor])
                    cursor += 1
                    guard cursor + size <= data.count else { return layout }
                    if size >= 8, Array(data[cursor..<cursor + 8]) == Array("NETSCAPE".utf8) {
                        layout.animated = true
                        if !untilFirstFrame { return layout }
                    }
                    cursor += size
                    guard skipSub(data, &cursor) else { return layout }
                } else if label == 0xFE, untilFirstFrame {
                    guard let text = readSub(data, &cursor) else { return layout }
                    layout.comment += String(data: Data(text), encoding: .utf8)
                        ?? String(data: Data(text), encoding: .isoLatin1) ?? ""
                } else if !skipSub(data, &cursor) {
                    return layout
                }
                continue
            }

            if block == 0x2C {
                frames += 1
                if frames >= 2 {
                    layout.animated = true
                    return layout
                }
                guard cursor + 9 <= data.count else { return layout }
                let packed = data[cursor + 8]
                layout.interlaced = packed & 0x40 != 0
                if untilFirstFrame { return layout }
                cursor += 9
                guard skip(data, &cursor, colorTable(packed)), cursor < data.count else { return layout }
                cursor += 1
                guard skipSub(data, &cursor) else { return layout }
                continue
            }

            return layout
        }
        return layout
    }

    private static func colorTable(_ packed: UInt8) -> Int {
        packed & 0x80 == 0 ? 0 : 3 * (1 << (Int(packed & 0x07) + 1))
    }

    private static func skip(_ data: [UInt8], _ cursor: inout Int, _ count: Int) -> Bool {
        guard count >= 0, cursor + count <= data.count else { return false }
        cursor += count
        return true
    }

    private static func skipSub(_ data: [UInt8], _ cursor: inout Int) -> Bool {
        while cursor < data.count {
            let length = Int(data[cursor])
            cursor += 1
            if length == 0 { return true }
            if !skip(data, &cursor, length) { return false }
        }
        return false
    }

    private static func readSub(_ data: [UInt8], _ cursor: inout Int) -> [UInt8]? {
        var bytes: [UInt8] = []
        while cursor < data.count {
            let length = Int(data[cursor])
            cursor += 1
            if length == 0 { return bytes }
            guard cursor + length <= data.count else { return nil }
            bytes += data[cursor..<cursor + length]
            cursor += length
        }
        return nil
    }
}
