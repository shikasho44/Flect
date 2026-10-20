import Foundation
import FlectCore
import FlectKit

// Mirrors evals/Evals/OutputTests.cs.
enum OutputEvals {
    private static func json(_ folder: String) throws -> String {
        let path = Paths.join(folder, "data.json")
        try Data(#"{"b":1,"a":2}"#.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    static func register(_ suite: Suite) {
        suite.test("Output goes beside the original by default") {
            Harness.useSettings()
            let source = try Paths.folder("output-default")
            try await Harness.run("json.pretty", [try json(source)])
            try expect(Paths.exists(Paths.join(source, "data_pretty.json")), "missing beside the original")
        }

        suite.test("Output goes to an absolute folder") {
            let source = try Paths.folder("output-absolute")
            let target = try Paths.folder("output-absolute-target")
            Harness.useSettings { $0.output.folders["json.pretty"] = target }
            try await Harness.run("json.pretty", [try json(source)])
            try expect(Paths.exists(Paths.join(target, "data_pretty.json")), "missing in the target")
            try expect(!Paths.exists(Paths.join(source, "data_pretty.json")), "also written beside the original")
        }

        suite.test("Output goes to a folder relative to the original") {
            let source = try Paths.folder("output-relative")
            Harness.useSettings { $0.output.folders["json.pretty"] = "./pretty" }
            try await Harness.run("json.pretty", [try json(source)])
            try expect(Paths.exists(Paths.join(source, "pretty/data_pretty.json")), "missing in ./pretty")
            try expect(!Paths.exists(Paths.join(source, "data_pretty.json")), "also written beside the original")
        }

        suite.test("Output folders expand ~, $NAME and %NAME%") {
            let source = try Paths.folder("output-variables")
            let target = try Paths.folder("output-variables-target")
            setenv("FLECT_OUTPUT_TEST", target, 1)
            defer { unsetenv("FLECT_OUTPUT_TEST") }
            for text in ["%FLECT_OUTPUT_TEST%", "$FLECT_OUTPUT_TEST", "${FLECT_OUTPUT_TEST}"] {
                Harness.useSettings { $0.output.folders["json.pretty"] = text }
                let directory = try OutputPath.$taskId.withValue("json.pretty") {
                    try OutputPath.directory(for: Paths.join(source, "data.json"))
                }
                try expect(directory == URL(fileURLWithPath: target).standardizedFileURL.path, "\(text) -> \(directory)")
            }
            Harness.useSettings { $0.output.folders["json.pretty"] = "~" }
            let home = try OutputPath.$taskId.withValue("json.pretty") {
                try OutputPath.directory(for: Paths.join(source, "data.json"))
            }
            try expect(home == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path, "~ -> \(home)")
        }

        suite.test("A folder cannot be compressed into itself") {
            let source = try Paths.folder("output-inside")
            Harness.useSettings { $0.output.folders["folder.compress"] = Paths.join(source, "archives") }
            do {
                _ = try OutputPath.$taskId.withValue("folder.compress") { try OutputPath.directory(for: source) }
                throw EvalFailure(description: "no error for an output inside the source")
            } catch let error as FlectError {
                try expect(error.message == Loc.t("msg.outputInsideSource"), error.message)
            }
        }

        suite.test("Compressing a folder to another output folder") {
            let parent = try Paths.folder("output-compress")
            let source = Paths.join(parent, "album")
            try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
            _ = try json(source)
            Harness.useSettings { $0.output.folders["folder.compress"] = "./archives" }
            try await Harness.run("folder.compress", [source])
            try expect(Paths.exists(Paths.join(parent, "archives/album.zip")), "\(Paths.listing(parent))")
        }

        suite.test("Both subtitle menus share one output folder") {
            try expect(OutputCatalog.key(for: "audio.subtitles") == "subtitles"
                       && OutputCatalog.key(for: "video.subtitles") == "subtitles"
                       && OutputCatalog.key(for: "jar.decompile") == nil, "catalog")
        }

        suite.test("Output folders keep the Windows settings file shape") {
            Harness.useSettings { $0.output.folders["video.resize"] = "./Resized" }
            let file = Store.directory.appendingPathComponent(Settings.fileName)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            let folders = (object?["Output"] as? [String: Any])?["Folders"] as? [String: String]
            try expect(folders == ["video.resize": "./Resized"], "\(object?["Output"] ?? "none")")

            let windows = #"{"Version":1,"Output":{"Folders":{"image.compress":"%USERPROFILE%\\Pictures\\Small","subtitles":"./subs"}}}"#
            try Data(windows.utf8).write(to: file)
            let loaded = Settings.reload()
            try expect(loaded.output.folders["subtitles"] == "./subs"
                       && loaded.output.folders["image.compress"] == #"%USERPROFILE%\Pictures\Small"#,
                       "\(loaded.output.folders)")
        }
    }
}
