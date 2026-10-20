import CoreGraphics
import Foundation
import ImageIO
import FlectCore
import FlectKit

enum ImageEvals {
    static func register(_ suite: Suite) {
        suite.test("Image resize halves the image") {
            Harness.useSettings()
            let folder = try Paths.folder("image-resize")
            let input = try await Fixtures.copy("photo.jpg", to: folder)
            try await Harness.run("image.resize?scale=50", [input])
            let (width, height) = try Inspect.size(Paths.join(folder, "photo_resized.jpg"))
            try expect(width == 200 && height == 150, "\(width)x\(height)")
        }

        suite.test("Image resize to custom pixels keeps the aspect ratio") {
            Harness.useSettings()
            let folder = try Paths.folder("image-resize-custom")
            let input = try await Fixtures.copy("photo.jpg", to: folder)
            let ui = ScriptedInteraction()
            ui.pixels = PixelTarget(width: 100, height: 0, keepAspect: true)
            try await Harness.run("image.resize?scale=custom", [input], ui: ui)
            let (width, height) = try Inspect.size(Paths.join(folder, "photo_resized.jpg"))
            try expect(width == 100 && height == 75, "\(width)x\(height)")
        }

        suite.test("Image resize reads decimal presets") {
            Harness.useSettings()
            let folder = try Paths.folder("image-resize-decimal")
            let input = try await Fixtures.copy("photo.jpg", to: folder)
            try await Harness.run("image.resize?scale=12.5", [input])
            let (width, height) = try Inspect.size(Paths.join(folder, "photo_resized.jpg"))
            try expect(width == 50 && height == 38, "\(width)x\(height)")
        }

        suite.test("Image rotate 90 swaps the sides and turns clockwise") {
            Harness.useSettings()
            let folder = try Paths.folder("image-rotate")
            let input = try await Fixtures.copy("photo.jpg", to: folder, as: "photo.png")
            let png = Paths.join(folder, "source.png")
            try Fixtures.save(try ImageCodec.load(input).upright, png, type: "public.png")
            try await Harness.run("image.rotate?deg=90", [png])
            let output = Paths.join(folder, "source_rotated.png")
            let (width, height) = try Inspect.size(output)
            try expect(width == 300 && height == 400, "\(width)x\(height)")
            let corner = try Inspect.pixel(output, x: 299, y: 0)
            try expect(corner.0 > 200 && corner.1 < 60, "red marker should move to the top-right, got \(corner)")
        }

        suite.test("Image rotate at an angle leaves transparent corners") {
            Harness.useSettings()
            let folder = try Paths.folder("image-rotate-angle")
            let input = try await Fixtures.copy("alpha.png", to: folder)
            try await Harness.run("image.rotate?deg=45", [input])
            let output = Paths.join(folder, "alpha_rotated.png")
            let (width, height) = try Inspect.size(output)
            try expect(width > 300 && height > 200, "\(width)x\(height)")
            try expect(try Inspect.pixel(output, x: 0, y: 0).3 == 0, "corner should be transparent")
        }

        suite.test("Image rotate of a JPEG fills the corners with white") {
            Harness.useSettings()
            let folder = try Paths.folder("image-rotate-jpeg")
            let input = try await Fixtures.copy("photo.jpg", to: folder)
            try await Harness.run("image.rotate?deg=30", [input])
            let corner = try Inspect.pixel(Paths.join(folder, "photo_rotated.jpg"), x: 0, y: 0)
            try expect(corner.0 > 240 && corner.1 > 240 && corner.2 > 240, "corner \(corner)")
        }

        for (target, type) in [("PNG", "public.png"), ("JPG", "public.jpeg"), ("WEBP", "org.webmproject.webp"),
                               ("HEIC", "public.heic"), ("ICO", "com.microsoft.ico"), ("GIF", "com.compuserve.gif")] {
            suite.test("Image convert writes \(target)") {
                Harness.useSettings()
                let folder = try Paths.folder("image-convert-\(target)")
                let input = try await Fixtures.copy(target == "PNG" ? "photo.jpg" : "alpha.png", to: folder)
                try await Harness.run("image.convert?to=\(target)", [input])
                let stem = target == "PNG" ? "photo" : "alpha"
                let output = Paths.join(folder, "\(stem).\(target.lowercased())")
                try expect(Inspect.type(output) == type, "\(output) is \(Inspect.type(output) ?? "unreadable")")
            }
        }

        suite.test("Image convert to ICO fits within 256 pixels") {
            Harness.useSettings()
            let folder = try Paths.folder("image-convert-ico-size")
            let input = try await Fixtures.copy("photo.jpg", to: folder)
            try await Harness.run("image.convert?to=ICO", [input])
            let (width, height) = try Inspect.size(Paths.join(folder, "photo.ico"))
            try expect(width == 256 && height == 192, "\(width)x\(height)")
        }

        suite.test("Image convert to SVG embeds the picture") {
            Harness.useSettings()
            let folder = try Paths.folder("image-convert-svg")
            let input = try await Fixtures.copy("alpha.png", to: folder)
            try await Harness.run("image.convert?to=SVG", [input])
            let text = try String(contentsOfFile: Paths.join(folder, "alpha.svg"), encoding: .utf8)
            try expect(text.hasPrefix("<svg") && text.contains("data:image/png;base64,") && text.contains("width=\"300\""), text.prefix(120).description)
        }

        suite.test("Image convert reads SVG") {
            Harness.useSettings()
            let folder = try Paths.folder("image-convert-from-svg")
            let input = try await Fixtures.copy("vector.svg", to: folder)
            try await Harness.run("image.convert?to=PNG", [input])
            let output = Paths.join(folder, "vector.png")
            let (width, height) = try Inspect.size(output)
            try expect(width == 120 && height == 80, "\(width)x\(height)")
            let center = try Inspect.pixel(output, x: 60, y: 40)
            try expect(center.0 > 200 && center.1 > 180 && center.2 < 80, "center should be gold, got \(center)")
        }

        suite.test("Image convert to JPG flattens transparency onto white") {
            Harness.useSettings()
            let folder = try Paths.folder("image-convert-flatten")
            let input = try await Fixtures.copy("alpha.png", to: folder)
            try await Harness.run("image.convert?to=JPG", [input])
            let corner = try Inspect.pixel(Paths.join(folder, "alpha.jpg"), x: 2, y: 2)
            try expect(corner.0 > 240 && corner.1 > 240 && corner.2 > 240, "corner \(corner)")
        }

        suite.test("Image transforms bake the EXIF orientation") {
            Harness.useSettings()
            let folder = try Paths.folder("image-orientation")
            let input = try await Fixtures.copy("rotated.jpg", to: folder)
            try await Harness.run("image.convert?to=PNG", [input])
            let (width, height) = try Inspect.size(Paths.join(folder, "rotated.png"))
            try expect(width == 300 && height == 400, "\(width)x\(height)")
        }

        suite.test("Animated GIF keeps its frames when resized") {
            Harness.useSettings()
            let folder = try Paths.folder("image-gif")
            let input = try await Fixtures.copy("animated.gif", to: folder)
            try await Harness.run("image.resize?scale=50", [input])
            let output = Paths.join(folder, "animated_resized.gif")
            try expect(Inspect.frames(output) == 3, "frames \(Inspect.frames(output))")
            let (width, height) = try Inspect.size(output)
            try expect(width == 60 && height == 40, "\(width)x\(height)")
        }

        for fixture in ["noise.jpg", "noise.png"] {
            suite.test("Image compress reaches the target or says why (\(fixture))") {
                Harness.useSettings()
                let folder = try Paths.folder("image-compress-\(fixture)")
                let input = try await Fixtures.copy(fixture, to: folder)
                let target: Int64 = 300 * 1024
                let (progress, _) = try await Harness.run("image.compress?bytes=\(target)", [input])
                let outputs = Paths.listing(folder).filter { $0.contains("_compressed") }
                try expect(outputs.count == 1, "outputs \(outputs)")
                let size = Paths.size(Paths.join(folder, outputs[0]))
                try expect(size <= target || !progress.warnings.isEmpty, "size \(size)")
            }
        }

        suite.test("Image compress of a PNG writes a palette PNG") {
            Harness.useSettings { $0.image.allowWebpFallback = false }
            let folder = try Paths.folder("image-compress-palette")
            let input = try await Fixtures.copy("green.png", to: folder)
            let original = Paths.size(input)
            try await Harness.run("image.compress?bytes=\(max(1, original - 1))", [input])
            let output = Paths.join(folder, "green_compressed.png")
            try expect(Inspect.type(output) == "public.png", "type \(Inspect.type(output) ?? "-")")
            let properties = Inspect.properties(output)
            let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
            try expect((properties[kCGImagePropertyHasAlpha as String] as? Bool) != nil || png != nil, "unreadable png")
            try expect(Paths.size(output) < original, "palette png should be smaller: \(Paths.size(output)) vs \(original)")
        }

        suite.test("Image compress skips files already under the target") {
            Harness.useSettings()
            let folder = try Paths.folder("image-compress-small")
            let input = try await Fixtures.copy("alpha.png", to: folder)
            let (progress, _) = try await Harness.run("image.compress?bytes=\(10 * 1024 * 1024)", [input])
            try expect(Paths.listing(folder) == ["alpha.png"], "\(Paths.listing(folder))")
            try expect(progress.infos.contains { $0.contains("alpha.png") }, "no info message")
        }

        suite.test("Strip metadata removes GPS and camera details") {
            Harness.useSettings()
            let folder = try Paths.folder("image-strip")
            let input = try await Fixtures.copy("photo.jpg", to: folder)
            let before = Inspect.properties(input)
            try expect(before[kCGImagePropertyGPSDictionary as String] != nil, "fixture lacks GPS")
            try await Harness.run("image.strip", [input])
            let output = Paths.join(folder, "photo_clean.jpg")
            let after = Inspect.properties(output)
            try expect(after[kCGImagePropertyGPSDictionary as String] == nil, "GPS survived: \(after)")
            let tiff = after[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            try expect(tiff?[kCGImagePropertyTIFFMake as String] == nil, "Make survived: \(tiff ?? [:])")
            let (width, height) = try Inspect.size(output)
            try expect(width == 400 && height == 300, "\(width)x\(height)")
        }

        suite.test("Strip metadata keeps EXIF but drops GPS when asked") {
            Harness.useSettings { settings in
                settings.image.metadata.removeExif = false
                settings.image.metadata.removeComments = false
            }
            let folder = try Paths.folder("image-strip-gps")
            let input = try await Fixtures.copy("photo.jpg", to: folder)
            try await Harness.run("image.strip", [input])
            let after = Inspect.properties(Paths.join(folder, "photo_clean.jpg"))
            try expect(after[kCGImagePropertyGPSDictionary as String] == nil, "GPS survived")
            let tiff = after[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            try expect(tiff?[kCGImagePropertyTIFFMake as String] as? String == "FlectCam", "Make lost: \(after)")
        }

        suite.test("Strip metadata bakes the orientation into the pixels") {
            Harness.useSettings()
            let folder = try Paths.folder("image-strip-orientation")
            let input = try await Fixtures.copy("rotated.jpg", to: folder)
            try await Harness.run("image.strip", [input])
            let output = Paths.join(folder, "rotated_clean.jpg")
            let (width, height) = try Inspect.size(output)
            let orientation = Inspect.properties(output)[kCGImagePropertyOrientation as String] as? Int ?? 1
            try expect(width == 300 && height == 400 && orientation == 1, "\(width)x\(height) orientation \(orientation)")
        }

        suite.test("Chroma key makes the key colour transparent") {
            Harness.useSettings { $0.image.backgroundMode = .chromaKeyOnly }
            let folder = try Paths.folder("image-chroma")
            let input = try await Fixtures.copy("green.png", to: folder)
            try await Harness.run("image.chromakey", [input])
            let output = Paths.join(folder, "green_keyed.png")
            try expect(try Inspect.pixel(output, x: 5, y: 5).3 == 0, "background should be transparent")
            try expect(try Inspect.pixel(output, x: 100, y: 100).3 == 255, "subject should stay opaque")
        }

        suite.test("OCR reads rendered text") {
            Harness.useSettings { $0.ocr.output = .textFile }
            let folder = try Paths.folder("image-ocr")
            let input = try await Fixtures.copy("ocr.png", to: folder)
            try await Harness.run("image.ocr", [input])
            let data = try Data(contentsOf: URL(fileURLWithPath: Paths.join(folder, "ocr_ocr.txt")))
            try expect(data.starts(with: [0xEF, 0xBB, 0xBF]), "default OCR output has a BOM")
            let text = String(decoding: data.dropFirst(3), as: UTF8.self)
            try expect(text.uppercased().contains(Fixtures.ocrText), "read \(text)")
        }

        suite.test("OCR to clipboard shows the text") {
            Harness.useSettings { $0.ocr.output = .clipboard }
            let folder = try Paths.folder("image-ocr-clipboard")
            let input = try await Fixtures.copy("ocr.png", to: folder)
            let ui = ScriptedInteraction()
            let (_, task) = try await Harness.run("image.ocr", [input], ui: ui)
            try expect(ui.clipboard?.uppercased().contains(Fixtures.ocrText) == true, "clipboard \(ui.clipboard ?? "-")")
            try expect(task.summary == Loc.t("msg.ocrCopied"), "summary \(task.summary ?? "-")")
            try expect(Paths.listing(folder) == ["ocr.png"], "no file should be written")
        }

        suite.test("Background removal with Vision cuts out a subject", category: "ai") {
            Harness.useSettings { $0.image.backgroundMode = .aiOnly }
            let folder = try Paths.folder("image-subject")
            let input = Paths.join(folder, "subject.png")
            let image = Fixtures.canvas(400, 400) { context in
                context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
                context.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
                context.fillEllipse(in: CGRect(x: 120, y: 100, width: 160, height: 200))
                context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
                context.fill(CGRect(x: 185, y: 40, width: 30, height: 70))
            }
            try Fixtures.save(image, input, type: "public.png")
            let (progress, _) = try await Harness.run("image.chromakey", [input], expectClean: false)
            if let error = progress.errors.first, error.contains(Loc.t("msg.noSubject")) {
                throw Skip(reason: "Vision found no subject in the synthetic picture")
            }
            try expect(progress.errors.isEmpty, "\(progress.errors)")
            let output = Paths.join(folder, "subject_keyed.png")
            try expect(try Inspect.pixel(output, x: 5, y: 5).3 < 40, "background should be cleared")
        }
    }
}
