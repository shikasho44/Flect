import CoreGraphics
import Foundation
import zlib

struct PaletteImage {
    var width: Int
    var height: Int
    var palette: [(UInt8, UInt8, UInt8, UInt8)]
    var indices: [UInt8]
}

enum Quantizer {
    fileprivate static let transparentKey = 1 << 19

    fileprivate struct Box {
        var keys: [Int]
        var population: Int
        var widest: Int
        var channel: Int
    }

    fileprivate struct Histogram {
        var counts: [Int32]
        var sums: [Int]

        init() {
            counts = [Int32](repeating: 0, count: transparentKey + 1)
            sums = [Int](repeating: 0, count: (transparentKey + 1) * 4)
        }

        func color(_ key: Int) -> (Int, Int, Int, Int) {
            let count = Int(counts[key])
            if count == 0 { return (0, 0, 0, 0) }
            let base = key * 4
            return ((sums[base] + count / 2) / count, (sums[base + 1] + count / 2) / count,
                    (sums[base + 2] + count / 2) / count, (sums[base + 3] + count / 2) / count)
        }
    }

    struct Prepared {
        fileprivate let histogram: Histogram
        fileprivate let keys: [Int32]
        fileprivate let used: [Int]
        let width: Int
        let height: Int

        func palette(colors limit: Int) -> PaletteImage {
            let reserved: [(UInt8, UInt8, UInt8, UInt8)] = histogram.counts[transparentKey] > 0 ? [(0, 0, 0, 0)] : []
            var palette = reserved
            if !used.isEmpty {
                palette += buildPalette(used, histogram, limit: max(1, limit - reserved.count))
            } else if palette.isEmpty {
                palette = [(0, 0, 0, 255)]
            }

            var mapping = [UInt8](repeating: 0, count: transparentKey + 1)
            let offset = reserved.count
            let opaque = Array(palette[offset...])
            for key in used { mapping[key] = UInt8(offset + nearestIndex(histogram.color(key), opaque)) }

            var indices = [UInt8](repeating: 0, count: keys.count)
            keys.withUnsafeBufferPointer { source in
                mapping.withUnsafeBufferPointer { table in
                    for pixel in 0..<source.count { indices[pixel] = table[Int(source[pixel])] }
                }
            }
            return PaletteImage(width: width, height: height, palette: palette, indices: indices)
        }
    }

    static func prepare(_ straight: [UInt8], width: Int, height: Int) -> Prepared {
        let pixelCount = width * height
        var histogram = Histogram()
        var keys = [Int32](repeating: 0, count: pixelCount)

        straight.withUnsafeBufferPointer { pixels in
            histogram.counts.withUnsafeMutableBufferPointer { counts in
                histogram.sums.withUnsafeMutableBufferPointer { sums in
                    for pixel in 0..<pixelCount {
                        let offset = pixel * 4
                        let alpha = Int(pixels[offset + 3])
                        let key: Int
                        if alpha == 0 {
                            key = transparentKey
                        } else {
                            let red: Int = Int(pixels[offset] >> 3)
                            let green: Int = Int(pixels[offset + 1] >> 3) << 5
                            let blue: Int = Int(pixels[offset + 2] >> 3) << 10
                            key = red | green | blue | (alpha >> 4) << 15
                            let base = key * 4
                            sums[base] += Int(pixels[offset])
                            sums[base + 1] += Int(pixels[offset + 1])
                            sums[base + 2] += Int(pixels[offset + 2])
                            sums[base + 3] += alpha
                        }
                        counts[key] += 1
                        keys[pixel] = Int32(key)
                    }
                }
            }
        }

        let used = (0..<transparentKey).filter { histogram.counts[$0] > 0 }
        return Prepared(histogram: histogram, keys: keys, used: used, width: width, height: height)
    }

    static func quantize(_ straight: [UInt8], width: Int, height: Int, colors limit: Int) -> PaletteImage {
        prepare(straight, width: width, height: height).palette(colors: limit)
    }

    fileprivate static func box(_ keys: [Int], _ histogram: Histogram) -> Box {
        var population = 0
        var lows = [255, 255, 255, 255]
        var highs = [0, 0, 0, 0]
        for key in keys {
            population += Int(histogram.counts[key])
            let color = histogram.color(key)
            let values = [color.0, color.1, color.2, color.3]
            for channel in 0..<4 {
                lows[channel] = min(lows[channel], values[channel])
                highs[channel] = max(highs[channel], values[channel])
            }
        }
        var widest = 0
        var channel = 0
        for candidate in 0..<4 where highs[candidate] - lows[candidate] > widest {
            widest = highs[candidate] - lows[candidate]
            channel = candidate
        }
        return Box(keys: keys, population: population, widest: widest, channel: channel)
    }

    fileprivate static func buildPalette(_ used: [Int], _ histogram: Histogram, limit: Int) -> [(UInt8, UInt8, UInt8, UInt8)] {
        if used.count <= limit {
            return used.map { key in
                let color = histogram.color(key)
                return (UInt8(color.0), UInt8(color.1), UInt8(color.2), UInt8(color.3))
            }
        }

        var boxes = [box(used, histogram)]
        while boxes.count < limit {
            guard let position = boxes.indices.filter({ boxes[$0].keys.count > 1 && boxes[$0].widest > 0 })
                .max(by: { boxes[$0].widest * boxes[$0].population < boxes[$1].widest * boxes[$1].population })
            else { break }

            let split = boxes.remove(at: position)
            let channelValue: (Int) -> Int = { key in
                let color = histogram.color(key)
                return [color.0, color.1, color.2, color.3][split.channel]
            }
            let sorted = split.keys.sorted { channelValue($0) < channelValue($1) }
            let half = split.population / 2
            var running = 0
            var cut = 1
            for (offset, key) in sorted.enumerated() {
                running += Int(histogram.counts[key])
                if running >= half {
                    cut = max(1, min(sorted.count - 1, offset + 1))
                    break
                }
            }
            boxes.append(box(Array(sorted[0..<cut]), histogram))
            boxes.append(box(Array(sorted[cut...]), histogram))
        }

        return boxes.map { box in
            var totals = [0, 0, 0, 0]
            var weight = 0
            for key in box.keys {
                let base = key * 4
                for channel in 0..<4 { totals[channel] += histogram.sums[base + channel] }
                weight += Int(histogram.counts[key])
            }
            let average = totals.map { UInt8(min(255, max(0, weight > 0 ? ($0 + weight / 2) / weight : 0))) }
            return (average[0], average[1], average[2], average[3])
        }
    }

    fileprivate static func nearestIndex(_ color: (Int, Int, Int, Int), _ palette: [(UInt8, UInt8, UInt8, UInt8)]) -> Int {
        var best = 0
        var bestDistance = Int.max
        for (index, entry) in palette.enumerated() {
            let dr = color.0 - Int(entry.0)
            let dg = color.1 - Int(entry.1)
            let db = color.2 - Int(entry.2)
            let da = color.3 - Int(entry.3)
            let distance = dr * dr + dg * dg + db * db + 2 * da * da
            if distance < bestDistance {
                bestDistance = distance
                best = index
                if distance == 0 { break }
            }
        }
        return best
    }

    static func image(_ quantized: PaletteImage, colorSpace: CGColorSpace) -> CGImage {
        var straight = [UInt8](repeating: 0, count: quantized.width * quantized.height * 4)
        for (pixel, index) in quantized.indices.enumerated() {
            let entry = quantized.palette[Int(index)]
            straight[pixel * 4] = entry.0
            straight[pixel * 4 + 1] = entry.1
            straight[pixel * 4 + 2] = entry.2
            straight[pixel * 4 + 3] = entry.3
        }
        return Bitmap.premultiplied(straight, width: quantized.width, height: quantized.height, colorSpace: colorSpace)
            .makeImage()
    }
}

enum IndexedPng {
    static func encode(_ image: PaletteImage) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var header = Data()
        header.appendBigEndian(UInt32(image.width))
        header.appendBigEndian(UInt32(image.height))
        header.append(contentsOf: [8, 3, 0, 0, 0])
        chunk("IHDR", header, into: &data)

        var palette = Data()
        for entry in image.palette { palette.append(contentsOf: [entry.0, entry.1, entry.2]) }
        chunk("PLTE", palette, into: &data)

        if let lastTranslucent = image.palette.lastIndex(where: { $0.3 != 255 }) {
            chunk("tRNS", Data(image.palette[0...lastTranslucent].map { $0.3 }), into: &data)
        }

        var raw = [UInt8]()
        raw.reserveCapacity((image.width + 1) * image.height)
        for row in 0..<image.height {
            raw.append(0)
            raw.append(contentsOf: image.indices[(row * image.width)..<((row + 1) * image.width)])
        }
        chunk("IDAT", deflate(raw), into: &data)
        chunk("IEND", Data(), into: &data)
        return data
    }

    private static func deflate(_ bytes: [UInt8]) -> Data {
        var length = compressBound(uLong(bytes.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        var input = bytes
        let status = compress2(&output, &length, &input, uLong(input.count), 9)
        precondition(status == Z_OK, "zlib failed")
        return Data(output[0..<Int(length)])
    }

    private static func chunk(_ type: String, _ body: Data, into data: inout Data) {
        data.appendBigEndian(UInt32(body.count))
        var tagged = Data(type.utf8)
        tagged.append(body)
        data.append(tagged)
        let checksum = tagged.withUnsafeBytes { buffer in
            crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
        }
        data.appendBigEndian(UInt32(checksum))
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
