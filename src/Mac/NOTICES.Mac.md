# Third-Party Notices for Flect for Mac

Flect for Mac is the macOS port of [Flect](https://github.com/Konayukiw/Flect) by
[Konayukiw](https://github.com/Konayukiw), licensed under the **Apache License, Version 2.0**
(`LICENSE` at the root of the repository). The Windows components and their licences are listed
in `NOTICES.md`; the full licence texts referred to below (Apache-2.0, MIT, BSD-3-Clause, GPL-3.0
and LGPL-2.1) are reproduced at the end of that file.

The Mac app replaces ImageMagick, PDFium, PdfPig, 7-Zip, Windows OCR and the Python helpers with
frameworks that ship with macOS (ImageIO, Core Image, Vision, PDFKit, Speech, AVFoundation,
`/usr/bin/tar`). The components below are the ones it adds.

## Components

| Component | Version | License | How it is used |
| --- | --- | --- | --- |
| libwebp | 1.6.0 | BSD-3-Clause + patent grant | Compiled into the app to write `.webp` (`src/Mac/Sources/CWebP`) |
| FFmpeg / FFprobe | 9.0.2 | GPL-3.0 (built with `--enable-gpl --enable-version3`) | Separate executables in `Flect.app/Contents/Helpers` |
| x264 | stable `b35605ac` | GPL-2.0-or-later | Linked into the bundled ffmpeg |
| libvpx | 1.17.0 | BSD-3-Clause + patent grant | Linked into the bundled ffmpeg |
| LAME | 3.100 | LGPL-2.0-or-later | Linked into the bundled ffmpeg |
| Opus | 1.6.1 | BSD-3-Clause | Linked into the bundled ffmpeg |
| libvorbis | 1.3.7 | BSD-3-Clause | Linked into the bundled ffmpeg |
| libogg | 1.3.6 | BSD-3-Clause | Linked into the bundled ffmpeg |
| CFR | 0.152 | MIT | `cfr.jar` in `Flect.app/Contents/Resources/deps` |
| faster-whisper and its dependencies | installed on first use | MIT / BSD-3-Clause / Apache-2.0 | Optional Whisper subtitle engine, see `NOTICES.md` |

## Component Details

### libwebp - BSD 3-Clause License

- Project: <https://chromium.googlesource.com/webm/libwebp>
- Copyright (c) 2010, Google Inc. All rights reserved.
- The licence and the additional patent grant are in `src/Mac/Sources/CWebP/COPYING` and
  `src/Mac/Sources/CWebP/PATENTS`.

### FFmpeg, FFprobe and the libraries linked into them

`scripts/mac/build-ffmpeg.sh` builds the bundled `ffmpeg` and `ffprobe` from the official source
releases listed below, each checked against a pinned SHA-256. Because x264 is GPL, the resulting
executables are covered by the **GNU General Public License, version 3**. FFmpeg is not compiled
into Flect; the app starts it as a separate program.

| Source | Where it comes from |
| --- | --- |
| FFmpeg 9.0.2 | <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz> |
| x264 | <https://code.videolan.org/videolan/x264> (commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`) |
| libvpx 1.17.0 | <https://github.com/webmproject/libvpx> (tag `v1.17.0`) |
| LAME 3.100 | <https://lame.sourceforge.io> |
| Opus 1.6.1 | <https://opus-codec.org> |
| libvorbis 1.3.7, libogg 1.3.6 | <https://xiph.org> |

Under the terms of the GPL, the corresponding source code is available from these projects, and the
exact build recipe is `scripts/mac/build-ffmpeg.sh` in this repository.

- FFmpeg: Copyright (c) 2000-2026 the FFmpeg developers
- x264: Copyright (C) 2003-2025 x264 project
- libvpx: Copyright (c) 2010, The WebM Project authors. All rights reserved.
- LAME: Copyright (c) 1999-2017 the LAME project
- Opus: Copyright 2001-2023 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry,
  CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla, Amazon
- libvorbis and libogg: Copyright (c) 2002-2020 Xiph.org Foundation

### CFR - MIT License

- Project: <https://www.benf.org/other/cfr>
- Copyright (c) 2011- Lee Benfield
- Downloaded by `scripts/mac/fetch.sh` from <https://github.com/leibnitz27/cfr/releases/tag/0.152>.

## Runtime Prerequisites (Non-bundled)

- **Java runtime (JDK/JRE)** - only to decompile `.jar` files. Installed by the user.
- **Python 3.10+** - only for the optional Whisper subtitle engine. Installed by the user; Flect
  creates a private environment under `~/Library/Application Support/Flect/env` on first use.
- **Apple Speech models** - downloaded by macOS itself the first time the built-in subtitle engine
  needs a language.
