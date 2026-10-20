import Foundation
import PDFKit
import FlectCore
import FlectKit

enum DocumentEvals {
    static func write(_ path: String, _ data: Data) throws {
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    static func register(_ suite: Suite) {
        for (target, ext) in [("PNG", "png"), ("JPG", "jpg")] {
            suite.test("PDF convert renders every page (\(target))") {
                Harness.useSettings()
                let folder = try Paths.folder("pdf-convert-\(target)")
                let input = try await Fixtures.copy("alpha.pdf", to: folder)
                try await Harness.run("pdf.convert?to=\(target)", [input])
                let pages = Paths.listing(folder).filter { $0.hasSuffix(".\(ext)") }
                try expect(pages == ["alpha_p1.\(ext)", "alpha_p2.\(ext)"], "\(pages)")
                let (width, height) = try Inspect.size(Paths.join(folder, "alpha_p1.\(ext)"))
                try expect(width == 1240 && height == 1754, "\(width)x\(height) at 150 dpi")
            }
        }

        suite.test("PDF rotated pages render upright") {
            Harness.useSettings()
            let folder = try Paths.folder("pdf-rotated")
            let input = try await Fixtures.copy("alpha.pdf", to: folder)
            let document = PDFDocument(url: URL(fileURLWithPath: input))!
            document.page(at: 0)?.rotation = 90
            let rotated = Paths.join(folder, "turned.pdf")
            _ = document.write(to: URL(fileURLWithPath: rotated))
            try await Harness.run("pdf.convert?to=PNG", [rotated])
            let (width, height) = try Inspect.size(Paths.join(folder, "turned_p1.png"))
            try expect(width == 1754 && height == 1240, "\(width)x\(height)")
        }

        suite.test("PDF convert to text extracts the words") {
            Harness.useSettings()
            let folder = try Paths.folder("pdf-text")
            let input = try await Fixtures.copy("bravo.pdf", to: folder)
            try await Harness.run("pdf.convert?to=TXT", [input])
            let content = try text(Paths.join(folder, "bravo.txt"))
            try expect(content.contains("bravo page 1") && content.contains("bravo page 2"), content)
        }

        suite.test("PDF merge follows the chosen order") {
            Harness.useSettings()
            let folder = try Paths.folder("pdf-merge")
            let alpha = try await Fixtures.copy("alpha.pdf", to: folder)
            let bravo = try await Fixtures.copy("bravo.pdf", to: folder)
            let ui = ScriptedInteraction()
            ui.pdfOrder = { $0.reversed() }
            let (_, task) = try await Harness.run("pdf.merge", [alpha, bravo], ui: ui)
            let merged = PDFDocument(url: URL(fileURLWithPath: Paths.join(folder, "bravo_merged.pdf")))
            try expect(merged?.pageCount == 4, "pages \(merged?.pageCount ?? 0)")
            try expect(merged?.page(at: 0)?.string?.contains("bravo") == true, "first page should come from bravo")
            try expect(task.summary?.contains("bravo_merged.pdf") == true, task.summary ?? "-")
        }

        for (target, name, mark) in [("UTF8BOM", "jp_utf8bom.txt", [UInt8]([0xEF, 0xBB, 0xBF])),
                                     ("UTF16", "jp_utf16.txt", [0xFF, 0xFE])] {
            suite.test("Encode \(target) adds the right byte order mark") {
                Harness.useSettings()
                let folder = try Paths.folder("text-encode-\(target)")
                let input = Paths.join(folder, "jp.txt")
                try write(input, Data("日本語テキスト\n".utf8))
                try await Harness.run("text.encode?to=\(target)", [input])
                let data = try read(Paths.join(folder, name))
                try expect(data.starts(with: mark), "\(Array(data.prefix(4)))")
            }
        }

        suite.test("Encode to Shift_JIS round trips") {
            Harness.useSettings()
            let folder = try Paths.folder("text-sjis")
            let input = Paths.join(folder, "jp.txt")
            try write(input, Data("日本語テキスト①～\n".utf8))
            try await Harness.run("text.encode?to=SJIS", [input])
            let data = try read(Paths.join(folder, "jp_sjis.txt"))
            try expect(String(data: data, encoding: TextFile.shiftJis) == "日本語テキスト①～\n", "round trip failed")
            let (back, encoding) = try TextFile.read(Paths.join(folder, "jp_sjis.txt"))
            try expect(back == "日本語テキスト①～\n" && encoding.encoding == TextFile.shiftJis, "detection \(encoding)")
        }

        suite.test("Shift_JIS warns about characters it cannot hold") {
            Harness.useSettings()
            let folder = try Paths.folder("text-sjis-warn")
            let input = Paths.join(folder, "emoji.txt")
            try write(input, Data("abc😀def".utf8))
            let (progress, _) = try await Harness.run("text.encode?to=SJIS", [input])
            try expect(progress.warnings.count == 1, "\(progress.warnings)")
            try expect(String(data: try read(Paths.join(folder, "emoji_sjis.txt")), encoding: TextFile.shiftJis) == "abc?def", "replacement")
        }

        suite.test("Shift_JIS can refuse instead of replacing") {
            Harness.useSettings { $0.text.sjisFallback = .fail }
            let folder = try Paths.folder("text-sjis-fail")
            let input = Paths.join(folder, "emoji.txt")
            try write(input, Data("abc😀".utf8))
            let (progress, _) = try await Harness.run("text.encode?to=SJIS", [input], expectClean: false)
            try expect(progress.errors.count == 1 && !Paths.exists(Paths.join(folder, "emoji_sjis.txt")), "\(progress.errors)")
        }

        suite.test("Line endings become LF without adding a BOM") {
            Harness.useSettings()
            let folder = try Paths.folder("text-lf")
            let input = Paths.join(folder, "win.txt")
            try write(input, Data("one\r\ntwo\r\nthree".utf8))
            try await Harness.run("text.lineEndings?to=LF", [input])
            try expect(try read(Paths.join(folder, "win_lf.txt")) == Data("one\ntwo\nthree".utf8), "content")
        }

        suite.test("Line endings become CRLF and keep a UTF-8 BOM") {
            Harness.useSettings()
            let folder = try Paths.folder("text-crlf")
            let input = Paths.join(folder, "unix.txt")
            try write(input, Data([0xEF, 0xBB, 0xBF]) + Data("one\ntwo\n".utf8))
            try await Harness.run("text.lineEndings?to=CRLF", [input])
            try expect(try read(Paths.join(folder, "unix_crlf.txt")) == Data([0xEF, 0xBB, 0xBF]) + Data("one\r\ntwo\r\n".utf8), "content")
        }

        suite.test("CSV becomes every table format") {
            Harness.useSettings()
            let folder = try Paths.folder("text-csv")
            let input = Paths.join(folder, "people.csv")
            try write(input, Data("name,age,note\nAlice,30,\"says \"\"hi\"\"\"\nBob,25,\"line, with comma\"\n".utf8))
            for target in ["JSON", "XML", "HTML", "MD", "TXT"] {
                try await Harness.run("text.convert?to=\(target)", [input])
            }
            let json = try JSONParser.parse(try text(Paths.join(folder, "people.json")))
            try expect(json == .array([
                .object([("name", .string("Alice")), ("age", .string("30")), ("note", .string("says \"hi\""))]),
                .object([("name", .string("Bob")), ("age", .string("25")), ("note", .string("line, with comma"))]),
            ]), "json \(json)")
            try expect(try text(Paths.join(folder, "people.xml")).contains("<name>Alice</name>"), "xml")
            try expect(try text(Paths.join(folder, "people.html")).contains("<td>says &quot;hi&quot;</td>"), "html")
            try expect(try text(Paths.join(folder, "people.md")).contains("| Bob | 25 | line, with comma |"), "md")
        }

        suite.test("Semicolon CSV is detected") {
            Harness.useSettings()
            let folder = try Paths.folder("text-csv-semicolon")
            let input = Paths.join(folder, "euro.csv")
            try write(input, Data("a;b\n1;2\n3;4\n".utf8))
            let (progress, _) = try await Harness.run("text.convert?to=JSON", [input])
            try expect(progress.infos.count == 1, "\(progress.infos)")
            let json = try JSONParser.parse(try text(Paths.join(folder, "euro.json")))
            try expect(json == .array([.object([("a", .string("1")), ("b", .string("2"))]),
                                       .object([("a", .string("3")), ("b", .string("4"))])]), "\(json)")
        }

        suite.test("JSON becomes CSV and XML") {
            Harness.useSettings()
            let folder = try Paths.folder("text-json")
            let input = Paths.join(folder, "rows.json")
            try write(input, Data("[{\"id\": 1, \"tags\": [\"a\"], \"ok\": true}, {\"id\": 2, \"extra\": null}]".utf8))
            try await Harness.run("text.convert?to=CSV", [input])
            try await Harness.run("text.convert?to=XML", [input])
            let csv = try read(Paths.join(folder, "rows.csv"))
            try expect(csv.starts(with: [0xEF, 0xBB, 0xBF]), "CSV should carry a BOM")
            let csvText = String(decoding: csv.dropFirst(3), as: UTF8.self)
            try expect(csvText == "id,tags,ok,extra\n1,\"[\"\"a\"\"]\",true,\n2,,,\n", "csv:\n\(csvText)")
            let xml = try text(Paths.join(folder, "rows.xml"))
            try expect(xml.contains("<item>\n    <id>1</id>") && xml.contains("<extra />"), "xml:\n\(xml)")
        }

        suite.test("XML and INI become JSON") {
            Harness.useSettings()
            let folder = try Paths.folder("text-xml-ini")
            let xml = Paths.join(folder, "data.xml")
            try write(xml, Data("<root version=\"2\"><item>a</item><item>b</item><name>n</name></root>".utf8))
            let ini = Paths.join(folder, "app.ini")
            try write(ini, Data("top=1\n; comment\n[server]\nhost = example\nport=80\n".utf8))
            try await Harness.run("text.convert?to=JSON", [xml])
            try await Harness.run("text.convert?to=JSON", [ini])
            let fromXml = try JSONParser.parse(try text(Paths.join(folder, "data.json")))
            try expect(fromXml == .object([("@version", .string("2")), ("item", .array([.string("a"), .string("b")])),
                                           ("name", .string("n"))]), "\(fromXml)")
            let fromIni = try JSONParser.parse(try text(Paths.join(folder, "app.json")))
            try expect(fromIni == .object([("top", .string("1")),
                                           ("server", .object([("host", .string("example")), ("port", .string("80"))]))]), "\(fromIni)")
        }

        suite.test("JSON pretty print indents and keeps numbers") {
            Harness.useSettings()
            let folder = try Paths.folder("text-pretty")
            let input = Paths.join(folder, "data.json")
            try write(input, Data("{\"b\":1.50,\"a\":[1,2,{}],\"s\":\"日本 \\\"q\\\"\",// note\n\"e\":[],}".utf8))
            try await Harness.run("json.pretty", [input])
            let expected = "{\n  \"b\": 1.50,\n  \"a\": [\n    1,\n    2,\n    {}\n  ],\n  \"s\": \"日本 \\\"q\\\"\",\n  \"e\": []\n}"
            let actual = try text(Paths.join(folder, "data_pretty.json"))
            try expect(actual == expected, "got:\n\(actual)")
        }

        suite.test("JSON sort orders keys recursively") {
            Harness.useSettings { settings in
                settings.text.jsonSort.comparison = .natural
                settings.text.jsonSort.pinnedKeys = "id"
            }
            let folder = try Paths.folder("text-sort")
            let input = Paths.join(folder, "data.json")
            try write(input, Data("{\"file10\":1,\"id\":0,\"file2\":2,\"nested\":{\"z\":1,\"a\":2}}".utf8))
            try await Harness.run("json.sort", [input])
            let sorted = try JSONParser.parse(try text(Paths.join(folder, "data_sorted.json")))
            try expect(sorted == .object([("id", .number("0")), ("file2", .number("2")), ("file10", .number("1")),
                                          ("nested", .object([("a", .number("2")), ("z", .number("1"))]))]), "\(sorted)")
        }

        suite.test("Decompile recovers the source") {
            guard let java = try? Tools.java() else { throw Skip(reason: "no Java runtime on this Mac") }
            let bin = (java as NSString).deletingLastPathComponent
            let javac = (bin as NSString).appendingPathComponent("javac")
            let archiver = (bin as NSString).appendingPathComponent("jar")
            guard FileManager.default.isExecutableFile(atPath: javac), FileManager.default.isExecutableFile(atPath: archiver) else {
                throw Skip(reason: "needs a JDK with javac and jar")
            }
            Harness.useSettings()
            let folder = try Paths.folder("jar-decompile")
            let classes = Paths.join(folder, "classes")
            try write(Paths.join(folder, "Hello.java"),
                      Data("public class Hello { public static void main(String[] a) { System.out.println(\"flect\"); } }".utf8))
            try await ProcessRunner.runOrThrow(javac, ["-d", classes, Paths.join(folder, "Hello.java")])
            let jar = Paths.join(folder, "hello.jar")
            try await ProcessRunner.runOrThrow(archiver, ["cf", jar, "-C", classes, "."])
            try await Harness.run("jar.decompile", [jar])
            let source = try text(Paths.join(folder, "hello/Hello.java"))
            try expect(source.contains("class Hello") && source.contains("flect"), source)
        }
    }
}
