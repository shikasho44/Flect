import AppKit
import FinderSync
import SwiftUI
import FlectCore
import FlectKit

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.general.language != oldValue.general.language { Loc.use(settings.general.language) }
            if settings.general.theme != oldValue.general.theme { Theme.apply(settings.general.theme) }
        }
    }

    private init() { settings = AppSettings.current }

    func reset() {
        AppSettings.reset()
        settings = AppSettings()
        Loc.use(settings.general.language)
        Theme.apply(settings.general.theme)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, folder, video, image, text, ocr, code, output

    var id: String { rawValue }

    var title: String { Loc.t("settings.nav.\(rawValue)") }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .folder: return "folder"
        case .video: return "film"
        case .image: return "photo"
        case .text: return "doc.text"
        case .ocr: return "text.viewfinder"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .output: return "square.and.arrow.down"
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(page: SettingsPage = .general) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        window = WindowRegistry.shared.show(Branding.name, size: NSSize(width: 860, height: 640), resizable: true,
                                            onClose: { window = nil }) {
            SettingsView(store: SettingsStore.shared, page: page)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var page: SettingsPage?

    init(store: SettingsStore, page: SettingsPage = .general) {
        self.store = store
        _page = State(initialValue: page)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch page ?? .general {
                case .general: GeneralPage(store: store)
                case .folder: FolderPage(store: store)
                case .video: VideoPage(store: store)
                case .image: ImagePage(store: store)
                case .text: TextPage(store: store)
                case .ocr: OcrPage(store: store)
                case .code: CodePage(store: store)
                case .output: OutputPage(store: store)
                }
            }
            .formStyle(.grouped)
            .id(store.settings.general.language)
        }
    }
}

struct NumberField: View {
    var title: String
    @Binding var value: Double

    var body: some View {
        TextField(title, value: $value, format: .number.grouping(.never))
    }
}

struct IntField: View {
    var title: String
    @Binding var value: Int

    var body: some View {
        TextField(title, value: $value, format: .number.grouping(.never))
    }
}

struct ByteField: View {
    var title: String
    @Binding var value: Int64
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = Formatting.shortBytes(value) }
            .onChange(of: value) { if !focused { text = Formatting.shortBytes(value) } }
            .onChange(of: focused) { if !focused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if let bytes = Formatting.parseBytes(text) { value = bytes }
        text = Formatting.shortBytes(value)
    }
}

struct ExclusionEditor: View {
    @Binding var rules: ExclusionRules

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hint(Loc.t("settings.exclusions.hint"))
            HStack(alignment: .top, spacing: 10) {
                column(Loc.t("settings.exclusions.folders"), $rules.folders)
                column(Loc.t("settings.exclusions.files"), $rules.files)
                column(Loc.t("settings.exclusions.extensions"), $rules.extensions)
            }
        }
    }

    private func column(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
    }
}

struct GeneralPage: View {
    @ObservedObject var store: SettingsStore
    @State private var finderEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var updateText = ""
    @State private var checkingUpdate = false

    var body: some View {
        Form {
            Section(Loc.t("settings.general.finder")) {
                Label(finderEnabled ? Loc.t("settings.general.finder.on") : Loc.t("settings.general.finder.off"),
                      systemImage: finderEnabled ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(finderEnabled ? Color.green : Color.orange)
                HStack {
                    Button(Loc.t("settings.general.finder.open")) { FIFinderSyncController.showExtensionManagementInterface() }
                    Spacer()
                }
                Hint(Loc.t("settings.general.finder.hint"))
            }

            Section(Loc.t("settings.general.appearance")) {
                Picker(Loc.t("settings.general.theme"), selection: $store.settings.general.theme) {
                    Text(Loc.t("settings.general.theme.system")).tag(AppTheme.system)
                    Text(Loc.t("settings.general.theme.light")).tag(AppTheme.light)
                    Text(Loc.t("settings.general.theme.dark")).tag(AppTheme.dark)
                }
                Picker(Loc.t("settings.general.language"), selection: $store.settings.general.language) {
                    Text(Loc.t("settings.general.language.system")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("日本語").tag(AppLanguage.japanese)
                    Text("简体中文").tag(AppLanguage.chineseSimplified)
                }
                Hint(Loc.t("settings.general.language.hint"))
            }

            Section(Loc.t("settings.general.dialog")) {
                Toggle(Loc.t("settings.general.dialog.success"), isOn: $store.settings.general.closeOnSuccess)
                Toggle(Loc.t("settings.general.dialog.failure"), isOn: $store.settings.general.closeOnFailure)
                Toggle(Loc.t("settings.general.dialog.cancel"), isOn: $store.settings.general.closeOnCancel)
                Hint(Loc.t("settings.general.dialog.hint"))
            }

            Section(Loc.t("settings.general.menu")) {
                HStack {
                    Button(Loc.t("settings.general.menu.all")) { store.settings.general.hiddenMenuItems = [] }
                    Button(Loc.t("settings.general.menu.none")) {
                        store.settings.general.hiddenMenuItems = MenuCatalog.categories.map(\.id)
                    }
                    Spacer()
                }
                ForEach(MenuCatalog.categories, id: \.id) { entry in
                    MenuToggle(entry: entry, hidden: $store.settings.general.hiddenMenuItems)
                }
                Hint(Loc.t("settings.general.menu.hint"))
            }

            Section(Loc.t("settings.general.update")) {
                Toggle(Loc.t("settings.general.update.enable"), isOn: $store.settings.general.autoUpdate)
                HStack {
                    Button(Loc.t("settings.general.update.check")) {
                        checkingUpdate = true
                        updateText = Loc.t("settings.general.update.checking")
                        Task {
                            updateText = await UpdateCheck.run(interactive: true)
                            checkingUpdate = false
                        }
                    }
                    .disabled(checkingUpdate)
                    Text(updateText).foregroundStyle(.secondary)
                    Spacer()
                }
                Hint(Loc.t("settings.general.update.hint"))
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Branding.name) \(Branding.version)").font(.headline)
                        Text(Loc.t("app.credit")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(Loc.t("settings.reset")) {
                        if Dialog.confirm(Loc.t("settings.reset.confirm")) {
                            store.reset()
                            Dialog.info(Loc.t("settings.reset.done"))
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            finderEnabled = FIFinderSyncController.isExtensionEnabled
        }
    }
}

private struct MenuToggle: View {
    let entry: MenuEntry
    @Binding var hidden: [String]

    private var visible: Binding<Bool> {
        Binding(get: { !hidden.contains(entry.id) }, set: { on in
            if on { hidden.removeAll { $0 == entry.id } } else if !hidden.contains(entry.id) { hidden.append(entry.id) }
        })
    }

    var body: some View {
        if entry.children.isEmpty {
            Toggle(entry.displayName, isOn: visible)
        } else {
            DisclosureGroup {
                ForEach(entry.children, id: \.id) { child in MenuToggle(entry: child, hidden: $hidden) }
            } label: {
                Toggle(entry.displayName, isOn: visible)
            }
        }
    }
}

struct FolderPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section(Loc.t("settings.folder.duplicates")) {
                Picker(Loc.t("settings.folder.dup.strictness"), selection: $store.settings.folder.duplicates.strictness) {
                    Text(Loc.t("settings.folder.dup.sizeOnly")).tag(DuplicateStrictness.sizeOnly)
                    Text(Loc.t("settings.folder.dup.headHash")).tag(DuplicateStrictness.headHash)
                    Text(Loc.t("settings.folder.dup.fullContent")).tag(DuplicateStrictness.fullContent)
                }
                .pickerStyle(.radioGroup)
                LabeledContent(Loc.t("settings.folder.dup.extra")) {
                    VStack(alignment: .leading) {
                        Toggle(Loc.t("settings.folder.dup.matchName"), isOn: $store.settings.folder.duplicates.matchName)
                        Toggle(Loc.t("settings.folder.dup.matchTime"), isOn: $store.settings.folder.duplicates.matchTimestamp)
                    }
                }
                Toggle(Loc.t("settings.folder.dup.ignoreEmpty"), isOn: $store.settings.folder.duplicates.ignoreEmptyFiles)
                ByteField(title: Loc.t("settings.folder.dup.minimum"), value: $store.settings.folder.duplicates.minimumBytes)
                Picker(Loc.t("settings.folder.dup.keep"), selection: $store.settings.folder.duplicates.keep) {
                    Text(Loc.t("settings.folder.dup.keep.ask")).tag(DuplicateKeep.ask)
                    Text(Loc.t("settings.folder.dup.keep.oldest")).tag(DuplicateKeep.oldest)
                    Text(Loc.t("settings.folder.dup.keep.newest")).tag(DuplicateKeep.newest)
                }
            }

            Section(Loc.t("settings.folder.delete")) {
                Picker("", selection: $store.settings.folder.deleteMethod) {
                    Text(Loc.t("settings.folder.delete.recycle")).tag(DeleteMethod.recycleBin)
                    Text(Loc.t("settings.folder.delete.permanent")).tag(DeleteMethod.permanent)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if store.settings.folder.deleteMethod == .permanent {
                    Text(Loc.t("settings.folder.delete.warning")).foregroundStyle(.red)
                }
            }

            Section(Loc.t("settings.folder.scan")) {
                Hint(Loc.t("settings.folder.scan.hint"))
                ExclusionEditor(rules: $store.settings.folder.scanExclusions)
            }

            Section(Loc.t("settings.folder.rename")) {
                Toggle(Loc.t("settings.folder.rename.numbering"), isOn: $store.settings.folder.rename.useNumbering)
                IntField(title: Loc.t("settings.folder.rename.digits"), value: $store.settings.folder.rename.digitCount)
                Hint(Loc.t("settings.folder.rename.digitsHint"))
                IntField(title: Loc.t("settings.folder.rename.start"), value: $store.settings.folder.rename.startNumber)
                Toggle(Loc.t("settings.folder.rename.dryRun"), isOn: $store.settings.folder.rename.dryRun)
                ExclusionEditor(rules: $store.settings.folder.rename.exclusions)
            }

            Section(Loc.t("settings.folder.empty")) {
                Hint(Loc.t("settings.folder.empty.hint"))
                Toggle(Loc.t("settings.folder.empty.zero"), isOn: $store.settings.folder.empty.ignoreZeroByteFiles)
                Toggle(Loc.t("settings.folder.empty.desktopIni"), isOn: $store.settings.folder.empty.ignoreDesktopIni)
                Toggle(Loc.t("settings.folder.empty.thumbs"), isOn: $store.settings.folder.empty.ignoreThumbsDb)
                Hint(Loc.t("settings.folder.empty.macHint"))
            }

            Section(Loc.t("settings.folder.tree")) {
                Toggle(Loc.t("settings.folder.tree.foldersOnly"), isOn: $store.settings.folder.tree.foldersOnly)
                ExclusionEditor(rules: $store.settings.folder.tree.exclusions)
            }

            Section(Loc.t("settings.folder.analyze")) {
                Picker(Loc.t("settings.folder.analyze.format"), selection: $store.settings.folder.analyze.saveFormat) {
                    Text("CSV").tag(ReportFormat.csv)
                    Text("JSON").tag(ReportFormat.json)
                    Text("HTML").tag(ReportFormat.html)
                    Text("TXT").tag(ReportFormat.txt)
                }
                ExclusionEditor(rules: $store.settings.folder.analyze.exclusions)
            }

            Section(Loc.t("settings.folder.compress")) {
                Picker(Loc.t("settings.folder.compress.format"), selection: $store.settings.folder.archive.compressFormat) {
                    Text(Loc.t("settings.folder.compress.format.zip")).tag(ArchiveCompressFormat.zip)
                    Text(Loc.t("settings.folder.compress.format.sevenzip")).tag(ArchiveCompressFormat.sevenZip)
                    Text(Loc.t("settings.folder.compress.format.tar")).tag(ArchiveCompressFormat.tar)
                    Text(Loc.t("settings.folder.compress.format.targz")).tag(ArchiveCompressFormat.tarGz)
                }
                Hint(Loc.t("settings.folder.compress.hint"))
            }
        }
    }
}

private struct PresetSection: View {
    @Binding var resizeA: Double
    @Binding var resizeB: Double
    var compress: [(String, Binding<Int64>)]
    @Binding var rotateA: Double
    @Binding var rotateB: Double
    @Binding var rotateC: Double

    var body: some View {
        Section(Loc.t("settings.presets")) {
            Hint(Loc.t("settings.presets.hint"))
            LabeledContent(Loc.t("settings.presets.resize")) {
                HStack {
                    NumberField(title: "", value: $resizeA).frame(maxWidth: 80)
                    NumberField(title: "", value: $resizeB).frame(maxWidth: 80)
                }
            }
            ForEach(Array(compress.enumerated()), id: \.offset) { _, item in
                LabeledContent("\(Loc.t("settings.presets.compress")) - \(item.0)") {
                    ByteField(title: "", value: item.1).frame(maxWidth: 140)
                }
            }
            LabeledContent(Loc.t("settings.presets.rotate")) {
                HStack {
                    NumberField(title: "", value: $rotateA).frame(maxWidth: 80)
                    NumberField(title: "", value: $rotateB).frame(maxWidth: 80)
                    NumberField(title: "", value: $rotateC).frame(maxWidth: 80)
                }
            }
        }
    }
}

struct VideoPage: View {
    @ObservedObject var store: SettingsStore
    @State private var hardware: [HardwareEncoder]?
    @State private var ffmpeg = ""

    private var fillColor: Binding<Color> {
        Binding(get: {
            let color = ColorText.parse(store.settings.video.rotateFillColor, fallback: .black)
            return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
        }, set: { color in
            let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
            store.settings.video.rotateFillColor = ColorText.format(RGBColor(
                red: UInt8((resolved.redComponent * 255).rounded()), green: UInt8((resolved.greenComponent * 255).rounded()),
                blue: UInt8((resolved.blueComponent * 255).rounded())))
        })
    }

    var body: some View {
        Form {
            Section(Loc.t("settings.video.tools")) {
                Text(ffmpeg.isEmpty ? "…" : ffmpeg).foregroundStyle(.secondary).textSelection(.enabled)
            }

            PresetSection(resizeA: $store.settings.video.presets.resizeA, resizeB: $store.settings.video.presets.resizeB,
                          compress: [(Loc.t("menu.video.compress.discord"), $store.settings.video.presets.compressDiscord),
                                     (Loc.f("settings.presets.slot", 1), $store.settings.video.presets.compressA),
                                     (Loc.f("settings.presets.slot", 2), $store.settings.video.presets.compressB),
                                     (Loc.f("settings.presets.slot", 3), $store.settings.video.presets.compressC)],
                          rotateA: $store.settings.video.presets.rotateA, rotateB: $store.settings.video.presets.rotateB,
                          rotateC: $store.settings.video.presets.rotateC)

            Section(Loc.t("settings.video.encoding")) {
                Picker(Loc.t("settings.video.codec"), selection: $store.settings.video.codec) {
                    if store.settings.video.container != .webM {
                        Text(Loc.t("settings.video.codec.h264")).tag(VideoCodecChoice.h264)
                        Text(Loc.t("settings.video.codec.h265")).tag(VideoCodecChoice.h265)
                    }
                    Text(Loc.t("settings.video.codec.vp9")).tag(VideoCodecChoice.vp9)
                    Text(Loc.t("settings.video.codec.av1")).tag(VideoCodecChoice.av1)
                }
                Picker(Loc.t("settings.video.container"), selection: Binding(get: { store.settings.video.container }, set: { container in
                    store.settings.video.container = container
                    if container == .webM, !Containers.suitsWebM(store.settings.video.codec) { store.settings.video.codec = .vp9 }
                })) {
                    Text(Loc.t("settings.video.container.auto")).tag(VideoContainer.auto)
                    Text(Loc.t("settings.video.container.mp4")).tag(VideoContainer.mp4)
                    Text(Loc.t("settings.video.container.mkv")).tag(VideoContainer.mkv)
                    Text(Loc.t("settings.video.container.webm")).tag(VideoContainer.webM)
                }
                Hint(Loc.t("settings.video.container.hint"))
                Picker(Loc.t("settings.video.hardware"), selection: $store.settings.video.hardware) {
                    Text(Loc.t("settings.video.hardware.none")).tag(HardwareEncoder.none)
                    Text(Loc.t("settings.video.hardware.videotoolbox")).tag(HardwareEncoder.videoToolbox)
                }
                if let hardware, store.settings.video.hardware == .videoToolbox, !hardware.contains(.videoToolbox) {
                    Text(Loc.f("settings.video.hardware.missing", Loc.t("settings.video.hardware.videotoolbox"))).foregroundStyle(.orange)
                }
                Hint(Loc.t("settings.video.hardware.hint"))
                Picker(Loc.t("settings.video.priority"), selection: $store.settings.video.priority) {
                    Text(Loc.t("settings.video.priority.speed")).tag(EncodePriority.speed)
                    Text(Loc.t("settings.video.priority.balanced")).tag(EncodePriority.balanced)
                    Text(Loc.t("settings.video.priority.quality")).tag(EncodePriority.quality)
                }
                .pickerStyle(.segmented)
                Hint(Loc.t("settings.video.priority.hint"))
            }

            Section(Loc.t("settings.video.gif")) {
                IntField(title: Loc.t("settings.video.gif.fps"), value: $store.settings.video.gifFps)
                IntField(title: Loc.t("settings.video.gif.width"), value: $store.settings.video.gifMaxWidth)
                Picker(Loc.t("settings.video.gif.dither"), selection: $store.settings.video.gifDither) {
                    Text(Loc.t("settings.video.gif.dither.none")).tag(GifDither.none)
                    Text(Loc.t("settings.video.gif.dither.bayer")).tag(GifDither.bayer)
                    Text(Loc.t("settings.video.gif.dither.floyd")).tag(GifDither.floydSteinberg)
                }
            }

            Section(Loc.t("settings.video.rotate")) {
                ColorPicker(Loc.t("settings.video.rotate.fill"), selection: fillColor, supportsOpacity: false)
                Hint(Loc.t("settings.video.rotate.fillHint"))
            }

            Section(Loc.t("settings.video.trim")) {
                Picker(Loc.t("settings.video.trim.accuracy"), selection: $store.settings.video.trim.accuracy) {
                    Text(Loc.t("settings.video.trim.keyframe")).tag(TrimAccuracy.keyframe)
                    Text(Loc.t("settings.video.trim.exact")).tag(TrimAccuracy.exact)
                }
                .pickerStyle(.radioGroup)
                Hint(Loc.t("settings.video.trim.hint"))
            }

            Section(Loc.t("settings.video.thumbnail")) {
                Picker(Loc.t("settings.video.thumbnail.format"), selection: $store.settings.video.thumbnail.format) {
                    Text(Loc.t("settings.video.thumbnail.format.png")).tag(ThumbnailFormat.png)
                    Text(Loc.t("settings.video.thumbnail.format.jpg")).tag(ThumbnailFormat.jpg)
                }
                IntField(title: Loc.t("settings.video.thumbnail.quality"), value: $store.settings.video.thumbnail.quality)
                IntField(title: Loc.t("settings.video.thumbnail.width"), value: $store.settings.video.thumbnail.maxWidth)
                Hint(Loc.t("settings.video.thumbnail.hint"))
            }

            Section(Loc.t("settings.video.subtitles")) {
                Picker(Loc.t("settings.video.subtitles.engine"), selection: $store.settings.video.subtitles.engine) {
                    Text(Loc.t("settings.video.subtitles.engine.apple")).tag(SubtitleEngine.apple)
                    Text(Loc.t("settings.video.subtitles.engine.whisper")).tag(SubtitleEngine.whisper)
                }
                if store.settings.video.subtitles.engine == .whisper {
                    Picker(Loc.t("settings.video.subtitles.model"), selection: $store.settings.video.subtitles.model) {
                        Text(Loc.t("settings.video.subtitles.model.tiny")).tag(SubtitleModel.tiny)
                        Text(Loc.t("settings.video.subtitles.model.base")).tag(SubtitleModel.base)
                        Text(Loc.t("settings.video.subtitles.model.small")).tag(SubtitleModel.small)
                        Text(Loc.t("settings.video.subtitles.model.medium")).tag(SubtitleModel.medium)
                        Text(Loc.t("settings.video.subtitles.model.large")).tag(SubtitleModel.largeV3)
                        Text(Loc.t("settings.video.subtitles.model.turbo")).tag(SubtitleModel.turbo)
                    }
                }
                Picker(Loc.t("settings.video.subtitles.language"), selection: $store.settings.video.subtitles.language) {
                    Text(Loc.t("settings.video.subtitles.language.auto")).tag("")
                    ForEach(["ja", "en", "zh", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "th", "vi"], id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
                Picker(Loc.t("settings.video.subtitles.output"), selection: $store.settings.video.subtitles.output) {
                    Text(Loc.t("settings.video.subtitles.output.srt")).tag(SubtitleOutput.srt)
                    Text(Loc.t("settings.video.subtitles.output.vtt")).tag(SubtitleOutput.vtt)
                    Text(Loc.t("settings.video.subtitles.output.txt")).tag(SubtitleOutput.txt)
                }
                Hint(Loc.t("settings.video.subtitles.hint"))
            }
        }
        .task {
            let found = await Task.detached { () -> ([HardwareEncoder], String) in
                guard let path = Tools.ffmpegIfPresent else { return ([], "") }
                let result = try? await ProcessRunner.run(path, ["-hide_banner", "-version"])
                let version = result?.standardOutput.split(separator: "\n").first.map(String.init) ?? path
                return (Acceleration.usable(), version)
            }.value
            hardware = found.0
            ffmpeg = found.1.isEmpty ? Loc.t("settings.video.tools.missing") : found.1
        }
    }
}

struct ImagePage: View {
    @ObservedObject var store: SettingsStore

    private var keyColor: Binding<Color> {
        Binding(get: {
            let color = ColorText.parse(store.settings.image.backgroundKeyColor, fallback: .lime)
            return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
        }, set: { color in
            let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .green
            store.settings.image.backgroundKeyColor = ColorText.format(RGBColor(
                red: UInt8((resolved.redComponent * 255).rounded()), green: UInt8((resolved.greenComponent * 255).rounded()),
                blue: UInt8((resolved.blueComponent * 255).rounded())))
        })
    }

    var body: some View {
        Form {
            PresetSection(resizeA: $store.settings.image.presets.resizeA, resizeB: $store.settings.image.presets.resizeB,
                          compress: [(Loc.f("settings.presets.slot", 1), $store.settings.image.presets.compressA),
                                     (Loc.f("settings.presets.slot", 2), $store.settings.image.presets.compressB),
                                     (Loc.f("settings.presets.slot", 3), $store.settings.image.presets.compressC),
                                     (Loc.f("settings.presets.slot", 4), $store.settings.image.presets.compressD)],
                          rotateA: $store.settings.image.presets.rotateA, rotateB: $store.settings.image.presets.rotateB,
                          rotateC: $store.settings.image.presets.rotateC)

            Section(Loc.t("settings.image.compression")) {
                Toggle(Loc.t("settings.image.webpFallback"), isOn: $store.settings.image.allowWebpFallback)
                Hint(Loc.t("settings.image.webpFallback.hint"))
                LabeledContent(Loc.t("settings.image.webpQuality")) {
                    HStack {
                        Slider(value: Binding(get: { Double(store.settings.image.webpQuality) },
                                              set: { store.settings.image.webpQuality = Int($0.rounded()) }), in: 10...100)
                        Text("\(store.settings.image.webpQuality)").monospacedDigit().frame(width: 32)
                    }
                }
            }

            Section(Loc.t("settings.image.background")) {
                Picker(Loc.t("settings.image.background.mode"), selection: $store.settings.image.backgroundMode) {
                    Text(Loc.t("settings.image.background.mode.aiFallback")).tag(BackgroundRemovalMode.aiWithFallback)
                    Text(Loc.t("settings.image.background.mode.aiOnly")).tag(BackgroundRemovalMode.aiOnly)
                    Text(Loc.t("settings.image.background.mode.chromaOnly")).tag(BackgroundRemovalMode.chromaKeyOnly)
                }
                Hint(Loc.t("settings.image.background.mode.hint"))
                if store.settings.image.backgroundMode != .aiOnly {
                    ColorPicker(Loc.t("settings.image.background.color"), selection: keyColor, supportsOpacity: false)
                    LabeledContent(Loc.t("settings.image.background.tolerance")) {
                        HStack {
                            Slider(value: $store.settings.image.backgroundTolerance, in: 0...100)
                            Text("\(Int(store.settings.image.backgroundTolerance))").monospacedDigit().frame(width: 32)
                        }
                    }
                    Hint(Loc.t("settings.image.background.hint"))
                    if store.settings.image.backgroundMode == .aiWithFallback {
                        Hint(Loc.t("settings.image.background.fallbackHint"))
                    }
                } else {
                    Hint(Loc.t("settings.image.background.aiOnlyHint"))
                }
            }

            Section(Loc.t("settings.image.metadata")) {
                Toggle(Loc.t("settings.image.metadata.exif"), isOn: $store.settings.image.metadata.removeExif)
                Toggle(Loc.t("settings.image.metadata.gps"), isOn: $store.settings.image.metadata.removeGps)
                Toggle(Loc.t("settings.image.metadata.comments"), isOn: $store.settings.image.metadata.removeComments)
                Toggle(Loc.t("settings.image.metadata.profile"), isOn: $store.settings.image.metadata.removeColorProfile)
                Hint(Loc.t("settings.image.metadata.profileHint"))
                Toggle(Loc.t("settings.image.metadata.orientation"), isOn: $store.settings.image.metadata.applyOrientation)
            }
        }
    }
}

struct TextPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section(Loc.t("settings.text.sjis")) {
                Hint(Loc.t("settings.text.sjis.hint"))
                Picker("", selection: $store.settings.text.sjisFallback) {
                    Text(Loc.t("settings.text.sjis.replace")).tag(SjisFallback.replaceAndWarn)
                    Text(Loc.t("settings.text.sjis.substitute")).tag(SjisFallback.substitute)
                    Text(Loc.t("settings.text.sjis.fail")).tag(SjisFallback.fail)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if store.settings.text.sjisFallback == .substitute {
                    TextField(Loc.t("settings.text.sjis.character"), text: $store.settings.text.sjisSubstitute)
                }
            }

            Section(Loc.t("settings.text.json")) {
                Picker(Loc.t("settings.text.json.comparison"), selection: $store.settings.text.jsonSort.comparison) {
                    Text(Loc.t("settings.text.json.comparison.ordinal")).tag(JsonKeyOrder.ordinal)
                    Text(Loc.t("settings.text.json.comparison.ignoreCase")).tag(JsonKeyOrder.ignoreCase)
                    Text(Loc.t("settings.text.json.comparison.natural")).tag(JsonKeyOrder.natural)
                }
                Toggle(Loc.t("settings.text.json.descending"), isOn: $store.settings.text.jsonSort.descending)
                Toggle(Loc.t("settings.text.json.recursive"), isOn: $store.settings.text.jsonSort.recursive)
                Toggle(Loc.t("settings.text.json.arrays"), isOn: $store.settings.text.jsonSort.sortPrimitiveArrays)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Loc.t("settings.text.json.pinned"))
                    TextEditor(text: $store.settings.text.jsonSort.pinnedKeys)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    Hint(Loc.t("settings.text.json.pinned.hint"))
                }
            }

            Section(Loc.t("settings.text.toTxt")) {
                Hint(Loc.t("settings.text.toTxt.hint"))
            }
        }
    }
}

struct OcrPage: View {
    @ObservedObject var store: SettingsStore
    private let languages = TextRecognition.supportedLanguages

    var body: some View {
        Form {
            Section(Loc.t("settings.ocr.language")) {
                Picker(Loc.t("settings.ocr.language"), selection: $store.settings.ocr.language) {
                    Text(Loc.t("settings.ocr.language.system")).tag("")
                    ForEach(languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                LabeledContent(Loc.t("settings.ocr.language.installed")) {
                    Text(languages.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(Loc.t("settings.ocr.output")) {
                Picker("", selection: $store.settings.ocr.output) {
                    Text(Loc.t("settings.ocr.output.file")).tag(OcrOutput.textFile)
                    Text(Loc.t("settings.ocr.output.clipboard")).tag(OcrOutput.clipboard)
                    Text(Loc.t("settings.ocr.output.show")).tag(OcrOutput.showOnly)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if store.settings.ocr.output == .textFile {
                    Picker(Loc.t("settings.ocr.encoding"), selection: $store.settings.ocr.encoding) {
                        Text(Loc.t("settings.ocr.encoding.utf8")).tag(TextEncodingChoice.utf8)
                        Text(Loc.t("settings.ocr.encoding.utf8bom")).tag(TextEncodingChoice.utf8Bom)
                        Text(Loc.t("settings.ocr.encoding.utf16")).tag(TextEncodingChoice.utf16)
                        Text(Loc.t("settings.ocr.encoding.sjis")).tag(TextEncodingChoice.shiftJis)
                    }
                }
            }
        }
    }
}

struct CodePage: View {
    @ObservedObject var store: SettingsStore
    @State private var java = ""

    var body: some View {
        Form {
            Section(Loc.t("settings.code.decompile")) {
                LabeledContent(Loc.t("settings.code.decompile.output")) {
                    HStack {
                        TextField("", text: $store.settings.code.decompile.outputPath)
                        Button(Loc.t("common.browse")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                store.settings.code.decompile.outputPath = url.path
                            }
                        }
                    }
                }
                Hint(Loc.t("settings.code.decompile.output.hint"))
            }
            Section(Loc.t("settings.code.java")) {
                Text(java).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task {
            let found = await Task.detached { try? Tools.java() }.value
            java = found.map { Loc.f("settings.code.java.found", $0) } ?? Loc.t("settings.code.java.missing")
        }
    }
}

struct OutputPage: View {
    @ObservedObject var store: SettingsStore
    @State private var adding = ""

    private var chosen: [OutputFeature] {
        OutputCatalog.features.filter { store.settings.output.folders[$0.key] != nil }
    }

    private var remaining: [OutputFeature] {
        OutputCatalog.features.filter { store.settings.output.folders[$0.key] == nil }
    }

    var body: some View {
        Form {
            Section(Loc.t("settings.output.title")) {
                ForEach(chosen, id: \.key) { feature in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(feature.label)
                        HStack {
                            TextField("", text: folder(feature.key), prompt: Text(Loc.t("settings.output.example")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Button(Loc.t("common.browse")) { browse(feature.key) }
                            Button(Loc.t("common.default")) { store.settings.output.folders[feature.key] = nil }
                        }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Picker("", selection: $adding) {
                        ForEach(remaining, id: \.key) { feature in Text(feature.label).tag(feature.key) }
                    }
                    .labelsHidden()
                    .disabled(remaining.isEmpty)
                    Button(Loc.t("settings.output.add")) {
                        store.settings.output.folders[adding] = ""
                        adding = remaining.first?.key ?? ""
                    }
                    .disabled(remaining.isEmpty || adding.isEmpty)
                }
                Hint(Loc.t("settings.output.hint"))
            }
        }
        .onAppear { adding = remaining.first?.key ?? "" }
        // Like the Windows page, a row left empty goes back to writing beside the original.
        .onDisappear {
            store.settings.output.folders = store.settings.output.folders.filter {
                !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    private func folder(_ key: String) -> Binding<String> {
        Binding(get: { store.settings.output.folders[key] ?? "" },
                set: { store.settings.output.folders[key] = $0 })
    }

    private func browse(_ key: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        let current = ((store.settings.output.folders[key] ?? "") as NSString).expandingTildeInPath
        if current.hasPrefix("/"), FileSystem.isDirectory(current) { panel.directoryURL = URL(fileURLWithPath: current) }
        if panel.runModal() == .OK, let url = panel.url { store.settings.output.folders[key] = url.path }
    }
}
