<div align="center">

# Flect for Mac

**[English](/README.Mac.md) / [日本語](/README.Mac.Ja.md) / 简体中文**

**在访达中右键点按文件或文件夹，即可转换、压缩、调整尺寸等。**

[Konayukiw](https://github.com/Konayukiw) 的 [Flect](/README.Zh.md) 的 macOS 版。

</div>

---

## 安装

1. 打开 `Flect-<版本>-mac-arm64.dmg`，将 **Flect** 拖到 **应用程序** 文件夹。
2. 打开一次 Flect，会显示设置窗口。
3. 在 **通用 → 访达** 中点按 **打开扩展设置**，然后打开 **Flect**。

之后在访达中右键点按文件或文件夹并选择 **Flect** 即可。

不使用 Flect 菜单也能调用相同的操作。以下方式都会打开选择操作的窗口：

- 在访达中选中文件后按 **⇧⌘J**，或右键点按并选择“**服务 › 用 Flect 处理…**”（部分版本位于“快速操作”中）。即使没有打开访达扩展也能使用。快捷键可在 **系统设置 › 键盘 › 键盘快捷键 › 服务** 中更改。
- 把文件拖到程序坞中的 Flect 图标上；按住 ⌘ 将 Flect.app 拖到访达工具栏后，也可以拖放到那里。
- 在 Flect 中按 **⌘O** 并选择文件。

> **文件访问** - 首次处理“桌面”“文稿”“下载”中的文件时，macOS 会询问是否允许 Flect 访问该文件夹。每个文件夹允许一次即可。

> **首次打开** - 发布页上的版本未经 Apple 公证，首次打开时 macOS 会提示无法验证 Flect。请点按 **完成**，打开 **系统设置 › 隐私与安全性**，在下方 Flect 相关的提示处点按 **仍要打开**，再输入密码确认。每个版本只需一次。
>
> 如果访达菜单或扩展设置中没有出现 **Flect**，仍可把文件拖到程序坞中的 Flect 图标上，或在 Flect 中按 **⌘O**。请附上 macOS 版本在 [Issue](https://github.com/shikasho44/Flect/issues) 中告诉我们。

## 功能

与 Windows 版功能相同，菜单、设置和输出文件名也相同。

| | |
| --- | --- |
| **图片** | 调整尺寸、压缩到指定大小、任意角度旋转、PNG/JPG/WEBP/HEIC/ICO/GIF/SVG 互相转换、文字识别、删除元数据、删除背景 |
| **视频和音频** | 调整尺寸、剪切、缩略图、字幕、压缩到指定大小（含 Discord 预设）、旋转、转换为 MP4/MOV/MKV/M4A/AVI/WEBM/FLV/GIF、提取音频为 MP3/M4A/WAV/AIF/AIFF/AAC/OGG/WMA |
| **文件夹** | 删除重复文件、删除空文件夹、目录树、批量重命名、分析、压缩为 ZIP/7z/TAR/tar.gz |
| **压缩包** | 解压 ZIP、7z、TAR、tar.gz 和 RAR |
| **文本** | PDF 预览、合并、导出为 PNG/JPG/TXT；数据格式转换（CSV、JSON、XML、HTML、MD、INI）；UTF-8、UTF-8 (BOM)、UTF-16、Shift_JIS；CRLF 与 LF；JSON 格式化与按键排序；JAR 反编译 |

转换后的文件保存在原文件旁边，绝不会覆盖原文件。重名时会加上 ` (2)`、` (3)` 等。删除重复文件和删除空文件夹默认移到废纸篓，除非选择彻底删除。

### Mac 版的不同之处

| | Windows 版 | Mac 版 |
| --- | --- | --- |
| 菜单 | 资源管理器 › 显示更多选项 › Flect | 访达 › Flect（访达扩展），也可使用访达工具栏按钮和程序坞图标 |
| 图片处理 | ImageMagick | macOS 内置的 ImageIO 和 Core Image（写入 WebP 时使用内置的 libwebp） |
| 文字识别 | Windows OCR（需要语言包） | Vision（支持中文、日语、英语等，无需安装） |
| 删除背景 | rembg（Python，176 MB 模型） | Vision 主体识别（内置，无需下载） |
| 字幕 | faster-whisper（Python） | Apple 语音识别（内置）或 faster-whisper（Python 3.10+），在 设置 › 视频 中选择 |
| 硬件编码 | NVENC、Quick Sync、AMF | Apple VideoToolbox |
| 压缩包 | 7-Zip | macOS 内置的 `bsdtar`（libarchive）。Windows 上创建的含中文或日文名称的 ZIP 也会自动正确解压 |
| 删除 | 回收站 | 废纸篓 |
| 空文件夹 | 可忽略 `desktop.ini`、`Thumbs.db` | 始终忽略 `.DS_Store` 等访达文件，且不会进入 `.app` 等包内部 |

设置保存在 `~/Library/Application Support/Flect/settings.json`，格式与 Windows 版的 `settings.json` 相同。

## 系统要求

| | |
| --- | --- |
| **macOS** | macOS 14 Sonoma 或更高版本。新的字幕引擎需要 macOS 26 |
| **Java（JDK 或 JRE）** | 仅在反编译 `.jar` 时需要 |
| **Python 3.10+** | 仅在使用 Whisper 字幕引擎时需要 |

ffmpeg、ffprobe 和 CFR 已内置在应用中。所有处理都在本机进行，不会上传任何内容。开启自动检查更新时，Flect 每天最多向 GitHub API 查询一次是否有新版本。

## 开发

需要 Xcode Command Line Tools（Swift 6），不需要 Homebrew。

```sh
scripts/mac/fetch.sh      # 从官方源码构建 ffmpeg/ffprobe 并下载 cfr.jar（仅首次，约 10 分钟）
scripts/mac/build.sh      # 生成 dist/mac/Flect.app
scripts/mac/test.sh       # 运行测试（相当于 Windows 版的 evals/Evals）
scripts/mac/package.sh    # 打包为 .dmg
scripts/mac/install.sh    # 复制到 ~/Applications 并启用访达菜单
```

签名与公证、通用二进制、更新检查来源等请参阅 [README.Mac.md](/README.Mac.md#for-development)。

## 许可证

Flect for Mac 与 Flect 本体一样采用 [Apache License 2.0](LICENSE) 授权。本项目基于 @Konayukiw 创建的 [Flect](https://flect.konayuki.xyz)。

应用内含 FFmpeg（GPLv3，由 `scripts/mac/build-ffmpeg.sh` 从源码构建）、libwebp（BSD）和 CFR（MIT）。各组件及其许可证列在 [NOTICES.Mac.md](/src/Mac/NOTICES.Mac.md) 中。
