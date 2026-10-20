<div align="center">

# Flect for Mac

**[English](/README.Mac.md) / 日本語 / [简体中文](/README.Mac.Zh.md)**

**Finder でファイルやフォルダを右クリックするだけで、変換・圧縮・リサイズなどができます。**

[Konayukiw](https://github.com/Konayukiw) さんの [Flect](/README.Ja.md) の macOS 版です。

</div>

---

## インストール

1. `Flect-<バージョン>-mac-arm64.dmg` を開き、**Flect** を **アプリケーション** フォルダへドラッグします。
2. Flect を一度開きます。設定ウインドウが表示されます。
3. **一般 → Finder** の **拡張機能の設定を開く** を押し、**Flect** をオンにします。

あとは Finder でファイルやフォルダを右クリックし、**Flect** を選ぶだけです。

Flect のメニューを使わずに、同じ操作を呼び出すこともできます。どの方法でも、操作を選ぶウインドウが開きます。

- Finder でファイルを選んで **⇧⌘J** を押す。または右クリック →「**サービス**」→「**Flect で処理…**」（macOS によっては「クイックアクション」の中）。Finder 拡張をオンにしていなくても使えます。ショートカットは **システム設定 › キーボード › キーボードショートカット › サービス** で変えられます。
- Dock の Flect アイコンにファイルをドロップする。Flect.app を ⌘ を押しながら Finder のツールバーへドラッグしておけば、そこへのドロップでも使えます。
- Flect で **⌘O** を押してファイルを選ぶ。

> **ファイルへのアクセス** - デスクトップ・書類・ダウンロードにあるファイルを初めて処理するとき、macOS がそのフォルダへのアクセスを許可するか尋ねます。フォルダごとに一度だけ許可してください。

> **初めて開くとき** - リリースページの配布物は Apple の公証を受けていないため、最初の1回は「Flect を検証できません」と止められます。**完了** を押してから **システム設定 › プライバシーとセキュリティ** を開き、下の方にある Flect の項目で **このまま開く** を押して、パスワードで確定してください。バージョンごとに1回だけ必要です。
>
> Finder のメニューや拡張機能の設定に **Flect** が出ない場合も、Dock の Flect アイコンにファイルをドロップするか、Flect で **⌘O** を押せば使えます。macOS のバージョンを添えて [Issue](https://github.com/shikasho44/Flect/issues) でお知らせください。

## 機能

Windows 版と同じ機能を、同じメニュー・設定・出力ファイル名で使えます。

| | |
| --- | --- |
| **画像** | リサイズ、指定サイズへの圧縮、任意角度の回転、PNG・JPG・WEBP・HEIC・ICO・GIF・SVG の相互変換、OCR、メタデータ削除、背景削除 |
| **動画・音声** | リサイズ、トリム、サムネイル、字幕、指定サイズへの圧縮（Discord 用プリセットあり）、回転、MP4・MOV・MKV・M4A・AVI・WEBM・FLV・GIF への変換、MP3・M4A・WAV・AIF・AIFF・AAC・OGG・WMA への音声抽出 |
| **フォルダ** | 重複削除、空フォルダ削除、ツリー表示、名前の一括変更、解析、ZIP・7z・TAR・tar.gz への圧縮 |
| **アーカイブ** | ZIP・7z・TAR・tar.gz・RAR の展開 |
| **テキスト** | PDF のプレビュー・結合・PNG/JPG/TXT への書き出し、データ形式の変換（CSV・JSON・XML・HTML・MD・INI）、UTF-8・UTF-8 (BOM)・UTF-16・Shift_JIS、CRLF と LF、JSON の整形とキー並べ替え、JAR の逆コンパイル |

変換したファイルは元のファイルの隣に保存され、元のファイルが上書きされることはありません。同じ名前がある場合は ` (2)`、` (3)` のように番号が付きます。重複削除と空フォルダ削除は、完全削除を選ばない限りゴミ箱へ移動します。

### Mac 版での違い

| | Windows 版 | Mac 版 |
| --- | --- | --- |
| メニュー | エクスプローラー › その他のオプションを確認 › Flect | Finder › Flect（Finder 拡張機能）。Finder のツールバーボタンと Dock アイコンからも使えます |
| 画像処理 | ImageMagick | macOS 内蔵の ImageIO・Core Image（WebP の書き出しのみ libwebp を同梱） |
| OCR | Windows の OCR（言語パックが必要） | Vision（日本語・中国語・英語など。追加のインストール不要） |
| 背景削除 | rembg（Python、176 MB のモデル） | Vision の被写体認識（内蔵、ダウンロード不要） |
| 字幕 | faster-whisper（Python） | Apple の音声認識（内蔵）か faster-whisper（Python 3.10 以降）を設定 › 動画 で選択 |
| ハードウェアエンコード | NVENC・Quick Sync・AMF | Apple VideoToolbox |
| アーカイブ | 7-Zip | macOS 内蔵の `bsdtar`（libarchive）。Windows で作られた日本語・中国語名の ZIP も自動で正しく展開します |
| 削除 | ごみ箱 | ゴミ箱 |
| 空フォルダ | `desktop.ini`・`Thumbs.db` を無視できる | `.DS_Store` などの Finder 用ファイルは常に無視。`.app` などのパッケージの中は調べません |

設定は `~/Library/Application Support/Flect/settings.json` に保存されます。形式は Windows 版の `settings.json` と同じです。

設定の **出力** で、機能ごとに結果の保存先フォルダを決められます（Windows 版と同じ）。設定しない機能は元ファイルの隣に保存します。`./Compressed` のような相対パスは元ファイルのあるフォルダが基準で、絶対パスと `~` もそのまま使えます。

## 動作環境

| | |
| --- | --- |
| **macOS** | macOS 14 Sonoma 以降。新しい字幕エンジンは macOS 26 以降 |
| **Java（JDK または JRE）** | `.jar` を逆コンパイルするときだけ必要 |
| **Python 3.10 以降** | Whisper の字幕エンジンを使うときだけ必要 |

ffmpeg・ffprobe・CFR はアプリに同梱されています。処理はすべてこの Mac の中で行われ、何もアップロードされません。アップデートの自動確認をオンにしている場合だけ、1 日 1 回 GitHub API に新しいリリースがあるかを問い合わせます。

## 開発者向け

Xcode Command Line Tools（Swift 6）が必要です。Homebrew は不要です。

```sh
scripts/mac/fetch.sh      # ffmpeg/ffprobe を公式ソースからビルドし、cfr.jar を取得（初回のみ、約10分）
scripts/mac/build.sh      # dist/mac/Flect.app を作成
scripts/mac/test.sh       # 検証一式を実行（Windows 版 evals/Evals に相当）
scripts/mac/package.sh    # .dmg を作成
scripts/mac/install.sh    # ~/Applications にコピーして Finder のメニューを有効化
```

署名・公証、ユニバーサルビルド、アップデートの確認先などの設定は [README.Mac.md](/README.Mac.md#for-development) を参照してください。

## ライセンス

Flect for Mac は Flect 本体と同じく [Apache License 2.0](LICENSE) で配布しています。本プロジェクトは @Konayukiw さんによって作成された [Flect](https://flect.konayuki.xyz) を元にしています。

アプリには FFmpeg（GPLv3、`scripts/mac/build-ffmpeg.sh` でソースからビルド）、libwebp（BSD）、CFR（MIT）が含まれます。各コンポーネントとライセンスは [NOTICES.Mac.md](/src/Mac/NOTICES.Mac.md) にまとめています。
