import CoreGraphics
import CoreVideo
import Foundation
import Vision
import FlectKit

enum SubjectLift {
    static func cutOut(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw FlectError(Loc.t("msg.noSubject"))
        }
        let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return try apply(mask, to: image)
    }

    private static func apply(_ mask: CVPixelBuffer, to image: CGImage) throws -> CGImage {
        let bitmap = Bitmap(image)
        var straight = bitmap.unpremultiplied()

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask),
              CVPixelBufferGetWidth(mask) == bitmap.width, CVPixelBufferGetHeight(mask) == bitmap.height else {
            throw FlectError(Loc.t("msg.bgAiFailed"))
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let format = CVPixelBufferGetPixelFormatType(mask)

        for row in 0..<bitmap.height {
            let line = base.advanced(by: row * rowBytes)
            for column in 0..<bitmap.width {
                let coverage: Double
                if format == kCVPixelFormatType_OneComponent32Float {
                    coverage = Double(line.assumingMemoryBound(to: Float32.self)[column])
                } else {
                    coverage = Double(line.assumingMemoryBound(to: UInt8.self)[column]) / 255
                }
                let offset = (row * bitmap.width + column) * 4 + 3
                straight[offset] = UInt8((Double(straight[offset]) * min(max(coverage, 0), 1)).rounded())
            }
        }
        return Bitmap.premultiplied(straight, width: bitmap.width, height: bitmap.height,
                                    colorSpace: bitmap.colorSpace).makeImage()
    }
}

enum ChromaKey {
    static func apply(_ image: CGImage, key: RGBColor, tolerance: Double) -> CGImage {
        let bitmap = Bitmap(image)
        var straight = bitmap.unpremultiplied()
        let limit = min(max(tolerance, 0), 100) / 100 * 255
        let threshold = max(limit * limit, 0.5)

        for offset in stride(from: 0, to: straight.count, by: 4) {
            let dr = Double(straight[offset]) - Double(key.red)
            let dg = Double(straight[offset + 1]) - Double(key.green)
            let db = Double(straight[offset + 2]) - Double(key.blue)
            if dr * dr + dg * dg + db * db <= threshold { straight[offset + 3] = 0 }
        }
        return Bitmap.premultiplied(straight, width: bitmap.width, height: bitmap.height,
                                    colorSpace: bitmap.colorSpace).makeImage()
    }
}

public enum TextRecognition {
    private static let comfortableEdge = 1600

    public static var supportedLanguages: [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    static func recognize(_ image: CGImage, language: String) throws -> String {
        var prepared = image
        let longest = max(image.width, image.height)
        if longest > 0, longest < comfortableEdge {
            let factor = Double(comfortableEdge) / Double(longest)
            prepared = ImageOps.resize(image, width: Int(Double(image.width) * factor), height: Int(Double(image.height) * factor))
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if language.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            let supported = supportedLanguages
            guard let match = supported.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame })
                ?? supported.first(where: { $0.lowercased().hasPrefix(language.lowercased().prefix(2)) }) else {
                throw FlectError(Loc.f("msg.ocrNoLanguage", language))
            }
            request.recognitionLanguages = [match]
        }

        let handler = VNImageRequestHandler(cgImage: prepared, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FlectError(Loc.t("msg.ocrNoEngine") + " " + describe(error))
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
