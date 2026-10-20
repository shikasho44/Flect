# CWebP

The encoder, decoder and DSP sources of [libwebp](https://chromium.googlesource.com/webm/libwebp) 1.6.0,
copied unmodified from the `v1.6.0` release tarball
(`sha256 93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136`).

ImageIO on macOS reads WebP but cannot write it, so Flect compiles libwebp into the app to save `.webp`.
The mux, demux and example tools are not included. The license is in `COPYING` and `PATENTS`.
