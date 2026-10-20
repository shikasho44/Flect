<div align="center">

# Flect for Mac

**English / [日本語](/README.Mac.Ja.md) / [简体中文](/README.Mac.Zh.md)**

**Right-click any files or folders in Finder to convert, compress, resize and more.**

The macOS port of [Flect](/README.md) by [Konayukiw](https://github.com/Konayukiw).

</div>

---

## Installation

1. Open `Flect-<version>-mac-arm64.dmg` and drag **Flect** into **Applications**.
2. Open Flect once. Its settings window appears.
3. In **General → Finder**, choose **Open Extension Settings** and turn on **Flect**.

After that, right-click files or folders in Finder and choose **Flect**.

The same actions are also available without the Flect menu. Each of these opens a window where you pick the action:

- Select files in Finder and press **⇧⌘J**, or right-click and choose **Services › Process with Flect…** (in **Quick Actions** on some versions). This works even when the Finder extension is not turned on. You can change the shortcut in **System Settings › Keyboard › Keyboard Shortcuts › Services**.
- Drop files on the Flect icon in the Dock, or on Flect.app after you ⌘-drag it into the Finder toolbar.
- Press **⌘O** in Flect and choose files.

> **File access** - the first time Flect works on files in Desktop, Documents or Downloads, macOS asks whether Flect may access that folder. Allow it once per folder.

> **First launch** - the builds on the Releases page are signed ad hoc and not notarized, so macOS blocks them the first time with a message that it cannot verify Flect. Choose **Done**, open **System Settings › Privacy & Security**, scroll down to the message about Flect and choose **Open Anyway**, then confirm with your password. You only need to do this once per version.
>
> If **Flect** does not appear in the Finder menu or in the extension settings, you can still drop files on the Flect icon in the Dock or press **⌘O** in Flect. Please [open an issue](https://github.com/shikasho44/Flect/issues) with your macOS version so we can look into it.

## Features

Everything the Windows version offers, with the same menu, settings and output names.

| | |
| --- | --- |
| **Images** | Resize, Compress to a target size, Rotate by any angle, Convert between PNG, JPG, WEBP, HEIC, ICO, GIF and SVG, OCR, Remove Metadata, Remove Background |
| **Videos & audio** | Resize, Trim, Thumbnail, Subtitles, Compress to a target size (Discord preset included), Rotate, Convert between MP4, MOV, MKV, M4A, AVI, WEBM, FLV and GIF, Extract Audio to MP3, M4A, WAV, AIF, AIFF, AAC, OGG and WMA |
| **Folders** | Remove Duplicate, Remove Empty, Tree, Rename, Analyze, Compress to ZIP, 7z, TAR or tar.gz |
| **Archives** | Extract ZIP, 7z, TAR, tar.gz and RAR |
| **Text files** | PDF preview, merge and export to PNG, JPG or TXT; data format conversion (CSV, JSON, XML, HTML, MD, INI); UTF-8, UTF-8 (BOM), UTF-16 and Shift_JIS; CRLF and LF; JSON pretty print and key sorting; JAR decompilation |

Converted files go next to the originals and are never overwritten - a name that is taken gets ` (2)`, ` (3)` and so on. Remove Duplicate and Remove Empty move files to the Trash unless you choose permanent deletion.

### What is different on the Mac

| | Windows | Mac |
| --- | --- | --- |
| Menu | Explorer › Show more options › Flect | Finder › Flect (a Finder extension), plus the Finder toolbar button and the Dock icon |
| Images | ImageMagick | ImageIO and Core Image, with libwebp for writing WebP |
| OCR | Windows OCR - needs a language pack | Vision - Japanese, Chinese, English and more, nothing to install |
| Remove Background | rembg (Python, 176 MB model) | Vision subject detection - built in, nothing to download |
| Subtitles | faster-whisper (Python) | Apple Speech (built in) or faster-whisper (Python 3.10+) - choose in Settings › Video |
| Hardware encoding | NVENC, Quick Sync, AMF | Apple VideoToolbox |
| Archives | 7-Zip | `bsdtar` (libarchive) that ships with macOS. Zips made on Windows with Japanese or Chinese names are decoded automatically |
| Deletion | Recycle Bin | Trash |
| Empty folders | `desktop.ini`, `Thumbs.db` can be ignored | `.DS_Store` and other Finder files are always ignored, and packages such as `.app` are never searched |

Settings live in `~/Library/Application Support/Flect/settings.json`, in the same format as the Windows `settings.json`.

**Output** in Settings chooses where each feature writes its results, as on Windows. Leave a feature out to write beside the original. A relative folder such as `./Compressed` starts from the original's folder; absolute paths and `~` work as written.

## Requirements

| | |
| --- | --- |
| **macOS** | macOS 14 Sonoma or later. The newer subtitle engine needs macOS 26 |
| **Java (JDK or JRE)** | Only to decompile `.jar` files |
| **Python 3.10+** | Only for the optional Whisper subtitle engine |

ffmpeg, ffprobe and CFR are inside the app. Everything runs on your Mac and nothing is uploaded. When automatic update checks are on, Flect asks the GitHub API once a day whether a newer release exists.

## For development

You need the Xcode Command Line Tools (Swift 6). Homebrew is not required.

```sh
scripts/mac/fetch.sh      # Builds ffmpeg/ffprobe from the official sources and downloads cfr.jar (about 10 minutes, once)
scripts/mac/build.sh      # Builds dist/mac/Flect.app
scripts/mac/test.sh       # Runs the evals (the Mac counterpart of evals/Evals)
scripts/mac/package.sh    # Wraps the app into a .dmg
scripts/mac/install.sh    # Copies the app into ~/Applications and turns the Finder menu on
```

- `FLECT_SIGNING_IDENTITY="Developer ID Application: …"` signs with hardened runtime; `FLECT_NOTARY_PROFILE` makes `package.sh` notarize and staple the disk image.
- `FLECT_ARCHS="arm64 x86_64"` builds a universal app (run `fetch.sh` with the same variable first; the x86_64 ffmpeg build needs `nasm`).
- `FLECT_UPDATE_REPOSITORY=owner/repo` chooses where the update check looks for releases (default `shikasho44/Flect`). A release counts for the Mac when it carries a `.dmg` or a `*mac*.zip` asset.
- `python3 scripts/mac/sync-strings.py` regenerates the Mac string tables from `src/App/Main/I18n`. Mac-only wording lives in `src/Mac/Sources/FlectKit/I18n/Strings+Mac.swift`.

### Layout

```
src/Mac/
├── Package.swift
├── Resources/          # Info.plist templates and the Finder extension entitlements
└── Sources/
    ├── FlectKit/       # Settings, translations, menu catalog, selection rules - shared with the extension
    ├── FlectFinder/    # Finder Sync extension that draws the menu (sandboxed, does no file work)
    ├── FlectCore/      # Every task: images, media, folders, archives, text, PDF, OCR, subtitles
    ├── FlectApp/       # The app: progress window, dialogs, settings, Finder hand-off
    ├── FlectEvals/     # Evaluation suite run by scripts/mac/test.sh
    └── CWebP/          # libwebp 1.6.0 sources
```

The Finder extension is the counterpart of `src/Shell`: it reads the settings, builds the same menu as `MenuBuilder.cpp` and hands the chosen verb and paths to the app through a `flect://` link carrying a per-install token. Links without the token ask before running anything.

## License

Flect for Mac is licensed under the [Apache License 2.0](LICENSE), like Flect itself, and is based on [Flect](https://flect.konayuki.xyz) created by @Konayukiw.

The app bundles FFmpeg (GPLv3, built from source by `scripts/mac/build-ffmpeg.sh`), libwebp (BSD) and CFR (MIT). Every component and its licence is listed in [NOTICES.Mac.md](/src/Mac/NOTICES.Mac.md).
