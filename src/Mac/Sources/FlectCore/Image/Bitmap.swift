import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct Bitmap {
    var width: Int
    var height: Int
    var pixels: [UInt8]
    var colorSpace: CGColorSpace

    var bytesPerRow: Int { width * 4 }

    static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    init(width: Int, height: Int, colorSpace: CGColorSpace, fill: UInt8 = 0) {
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        pixels = [UInt8](repeating: fill, count: width * height * 4)
    }

    init(_ image: CGImage, colorSpace: CGColorSpace? = nil) {
        let space = colorSpace ?? Bitmap.workingSpace(for: image)
        self.init(width: image.width, height: image.height, colorSpace: space)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = Bitmap.context(buffer.baseAddress, width, height, space) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func context(_ data: UnsafeMutableRawPointer?, _ width: Int, _ height: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    func makeImage() -> CGImage {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer in
            Bitmap.context(buffer.baseAddress, width, height, colorSpace)!.makeImage()!
        }
    }

    var hasTransparency: Bool {
        stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 255 }
    }

    func unpremultiplied() -> [UInt8] {
        var output = pixels
        output.withUnsafeMutableBytes { buffer in
            var image = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: bytesPerRow)
            _ = vImageUnpremultiplyData_RGBA8888(&image, &image, vImage_Flags(kvImageNoFlags))
        }
        return output
    }

    static func premultiplied(_ straight: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace) -> Bitmap {
        var bitmap = Bitmap(width: width, height: height, colorSpace: colorSpace)
        bitmap.pixels = straight
        bitmap.pixels.withUnsafeMutableBytes { buffer in
            var image = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width * 4)
            _ = vImagePremultiplyData_RGBA8888(&image, &image, vImage_Flags(kvImageNoFlags))
        }
        return bitmap
    }
}

enum ImageOps {
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    static func orient(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        if orientation == .up { return image }
        let source = Bitmap(image).makeImage()
        let oriented = CIImage(cgImage: source).oriented(orientation)
        return context.createCGImage(oriented, from: oriented.extent, format: .RGBA8,
                                     colorSpace: Bitmap.workingSpace(for: source)) ?? source
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let width = max(1, width)
        let height = max(1, height)
        if width == image.width, height == image.height { return image }

        let source = Bitmap(image)
        var target = Bitmap(width: width, height: height, colorSpace: source.colorSpace)
        var sourcePixels = source.pixels
        let status = sourcePixels.withUnsafeMutableBytes { input in
            target.pixels.withUnsafeMutableBytes { output -> vImage_Error in
                var from = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(source.height),
                                         width: vImagePixelCount(source.width), rowBytes: source.bytesPerRow)
                var to = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
                return vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        if status != kvImageNoError { return draw(image, width: width, height: height) }
        return target.makeImage()
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage {
        var target = Bitmap(width: width, height: height, colorSpace: Bitmap.workingSpace(for: image))
        target.pixels.withUnsafeMutableBytes { buffer in
            let context = Bitmap.context(buffer.baseAddress, width, height, target.colorSpace)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return target.makeImage()
    }

    static func scaled(_ image: CGImage, percent: Double) -> CGImage {
        resize(image, width: Int((Double(image.width) * percent / 100).rounded()),
               height: Int((Double(image.height) * percent / 100).rounded()))
    }

    static func fit(_ image: CGImage, width: Int, height: Int, exact: Bool) -> CGImage {
        if exact { return resize(image, width: width, height: height) }
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        return resize(image, width: Int((Double(image.width) * scale).rounded()),
                      height: Int((Double(image.height) * scale).rounded()))
    }

    static func rotate(_ image: CGImage, degrees: Double, background: CGColor?) -> CGImage {
        let turn = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if turn == 0 { return image }

        let radians = turn * .pi / 180
        let width = Double(image.width)
        let height = Double(image.height)
        let rightAngle = turn.truncatingRemainder(dividingBy: 90) == 0
        let cosine = rightAngle ? (cos(radians)).rounded() : cos(radians)
        let sine = rightAngle ? (sin(radians)).rounded() : sin(radians)
        let newWidth = Int((abs(width * cosine) + abs(height * sine)).rounded(.up))
        let newHeight = Int((abs(width * sine) + abs(height * cosine)).rounded(.up))

        var target = Bitmap(width: newWidth, height: newHeight, colorSpace: Bitmap.workingSpace(for: image))
        target.pixels.withUnsafeMutableBytes { buffer in
            let context = Bitmap.context(buffer.baseAddress, newWidth, newHeight, target.colorSpace)!
            if let background {
                context.setFillColor(background)
                context.fill(CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            }
            context.interpolationQuality = rightAngle ? .none : .high
            context.translateBy(x: Double(newWidth) / 2, y: Double(newHeight) / 2)
            context.rotate(by: -radians)
            context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        }
        return target.makeImage()
    }

    static func flatten(_ image: CGImage, onto color: CGColor) -> CGImage {
        var target = Bitmap(width: image.width, height: image.height, colorSpace: Bitmap.workingSpace(for: image))
        target.pixels.withUnsafeMutableBytes { buffer in
            let context = Bitmap.context(buffer.baseAddress, image.width, image.height, target.colorSpace)!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return target.makeImage()
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
}
