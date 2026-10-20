#!/bin/zsh
# Builds static ffmpeg and ffprobe for macOS from the official source releases,
# so the app bundle never carries a binary that nobody can rebuild.
#
#   scripts/mac/build-ffmpeg.sh            # host architecture
#   FLECT_ARCH=x86_64 scripts/mac/build-ffmpeg.sh
#
# The result lands in dependencies/mac/<arch>/. GPL components (x264) are included,
# exactly like the Windows build, and the binaries are released under the GPL v3.

set -euo pipefail

repo_root=${0:A:h:h:h}
arch=${FLECT_ARCH:-$(uname -m)}
minimum=${FLECT_MACOS_MINIMUM:-14.0}
sources=${FLECT_SOURCES:-$repo_root/build/mac/sources}
work=$repo_root/build/mac/ffmpeg-$arch
prefix=$work/prefix
destination=${FLECT_DEPS:-$repo_root/dependencies/mac}/$arch
jobs=$(sysctl -n hw.ncpu)

packages=(
  "lame-3.100.tar.gz|https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz|ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
  "libogg-1.3.6.tar.xz|https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz|5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061"
  "libvorbis-1.3.7.tar.xz|https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz|b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"
  "opus-1.6.1.tar.gz|https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz|6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
  "libvpx-1.17.0.tar.gz|https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz|1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"
  "x264-b35605ac.tar.bz2|https://code.videolan.org/videolan/x264/-/archive/b35605ace3ddf7c1a5d67a2eb553f034aef41d55/x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2|6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224"
  "ffmpeg-9.0.2.tar.xz|https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz|8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
)

case $arch in
  arm64) host=aarch64-apple-darwin; vpx_target=arm64-darwin25-gcc ;;
  x86_64) host=x86_64-apple-darwin; vpx_target=x86_64-darwin25-gcc ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

export MACOSX_DEPLOYMENT_TARGET=$minimum
export CFLAGS="-arch $arch -mmacosx-version-min=$minimum -O2"
export CXXFLAGS=$CFLAGS
export LDFLAGS="-arch $arch -mmacosx-version-min=$minimum"
export PKG_CONFIG_PATH=$prefix/lib/pkgconfig
export PATH=$prefix/bin:$PATH
pkg_config=${0:A:h}/pkg-config.py

fetch() {
  local name=$1 url=$2 sum=$3
  mkdir -p $sources
  if [[ ! -f $sources/$name ]]; then
    echo "  Downloading $name"
    curl -fsSL --retry 3 -o $sources/$name.part $url
    mv $sources/$name.part $sources/$name
  fi
  local actual=$(shasum -a 256 $sources/$name | awk '{print $1}')
  if [[ $actual != $sum ]]; then
    echo "Checksum mismatch for $name" >&2
    echo "  expected $sum" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
}

unpack() {
  local name=$1
  local folder=$work/src/${name%%.tar.*}
  rm -rf $folder
  mkdir -p $folder
  tar -xf $sources/$name -C $folder --strip-components 1
  echo $folder
}

built() { [[ -f $work/.done-$1 ]] }
mark() { touch $work/.done-$1 }

host_flag=()
[[ $arch != $(uname -m) ]] && host_flag=(--host=$host)

mkdir -p $work/src $prefix
for entry in $packages; do
  fetch ${(s:|:)entry}
done

if ! built lame; then
  echo "Building LAME"
  cd $(unpack lame-3.100.tar.gz)
  sed -i '' '/lame_init_old/d' include/libmp3lame.sym
  ./configure --prefix=$prefix --disable-shared --enable-static --disable-frontend \
    --disable-dependency-tracking $host_flag >/dev/null
  make -j$jobs install >/dev/null
  mark lame
fi

if ! built ogg; then
  echo "Building libogg"
  cd $(unpack libogg-1.3.6.tar.xz)
  ./configure --prefix=$prefix --disable-shared --enable-static $host_flag >/dev/null
  make -j$jobs install >/dev/null
  mark ogg
fi

if ! built vorbis; then
  echo "Building libvorbis"
  cd $(unpack libvorbis-1.3.7.tar.xz)
  sed -i '' 's/-force_cpusubtype_ALL//g' configure
  ./configure --prefix=$prefix --disable-shared --enable-static --with-ogg=$prefix \
    --disable-docs --disable-examples $host_flag >/dev/null
  make -j$jobs install >/dev/null
  mark vorbis
fi

if ! built opus; then
  echo "Building Opus"
  cd $(unpack opus-1.6.1.tar.gz)
  ./configure --prefix=$prefix --disable-shared --enable-static --disable-doc \
    --disable-extra-programs $host_flag >/dev/null
  make -j$jobs install >/dev/null
  mark opus
fi

if ! built vpx; then
  echo "Building libvpx"
  cd $(unpack libvpx-1.17.0.tar.gz)
  ./configure --prefix=$prefix --target=$vpx_target --disable-shared --enable-static \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-vp9-highbitdepth --enable-pic >/dev/null
  make -j$jobs install >/dev/null
  mark vpx
fi

if ! built x264; then
  echo "Building x264"
  cd $(unpack x264-b35605ac.tar.bz2)
  ./configure --prefix=$prefix --enable-static --disable-cli --enable-pic $host_flag \
    --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" >/dev/null
  make -j$jobs install >/dev/null
  mark x264
fi

echo "Building ffmpeg"
cd $(unpack ffmpeg-9.0.2.tar.xz)
cross=()
[[ $arch != $(uname -m) ]] && cross=(--enable-cross-compile --arch=$arch --target-os=darwin)
./configure \
  --prefix=$prefix \
  --pkg-config=$pkg_config \
  --pkg-config-flags=--static \
  --extra-cflags="-I$prefix/include $CFLAGS" \
  --extra-ldflags="-L$prefix/lib $LDFLAGS" \
  $cross \
  --enable-gpl --enable-version3 \
  --enable-static --disable-shared \
  --disable-ffplay --disable-doc --disable-debug --disable-network \
  --disable-sdl2 --disable-xlib --disable-libxcb \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-libx264 --enable-libvpx --enable-libmp3lame --enable-libopus --enable-libvorbis \
  >/dev/null
make -j$jobs >/dev/null

mkdir -p $destination
cp ffmpeg ffprobe $destination/
strip -x $destination/ffmpeg $destination/ffprobe 2>/dev/null || true

for tool in ffmpeg ffprobe; do
  if otool -L $destination/$tool | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)' | grep -q .; then
    echo "$tool links against a library outside the system:" >&2
    otool -L $destination/$tool >&2
    exit 1
  fi
done

echo "Built $(./ffmpeg -hide_banner -version | head -1)"
echo "Installed into $destination"
