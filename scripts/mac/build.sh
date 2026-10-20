#!/bin/zsh
# Builds dist/mac/Flect.app: the app, its Finder extension and the bundled tools.
#
#   scripts/mac/fetch.sh                  # once: ffmpeg, ffprobe and cfr.jar
#   scripts/mac/build.sh                  # release build for this Mac's architecture
#   FLECT_ARCHS="arm64 x86_64" scripts/mac/build.sh
#   FLECT_SIGNING_IDENTITY="Developer ID Application: …" scripts/mac/build.sh
#
# Without a signing identity the app is signed ad hoc, which is enough to run it on this Mac.

set -euo pipefail

repo_root=${0:A:h:h:h}
package=$repo_root/src/Mac
configuration=${1:-release}
archs=(${=FLECT_ARCHS:-$(uname -m)})
identity=${FLECT_SIGNING_IDENTITY:--}
bundle_id=${FLECT_BUNDLE_ID:-io.github.shikasho44.flect}
repository=${FLECT_UPDATE_REPOSITORY:-shikasho44/Flect}
deps=${FLECT_DEPS:-$repo_root/dependencies/mac}
dist=$repo_root/dist/mac
app=$dist/Flect.app
work=$repo_root/build/mac

props=$repo_root/Directory.Build.props
name=$(sed -n 's:.*<BrandName>\(.*\)</BrandName>.*:\1:p' $props)
version=$(sed -n 's:.*<BrandVersion>\(.*\)</BrandVersion>.*:\1:p' $props)
build=$(git -C $repo_root rev-list --count HEAD 2>/dev/null || echo 1)

export CLANG_MODULE_CACHE_PATH=$package/.build/clang-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=$package/.build/swiftpm-module-cache

binaries=()
for arch in $archs; do
  echo "Compiling $name $version for $arch ($configuration)"
  triple=(--triple $arch-apple-macosx14.0)
  swift build --package-path $package --disable-sandbox -c $configuration $triple --product Flect >/dev/null
  swift build --package-path $package --disable-sandbox -c $configuration $triple --product FlectFinder >/dev/null
  binaries+=($(swift build --package-path $package --disable-sandbox -c $configuration $triple --show-bin-path))
done

combine() {
  local product=$1 target=$2
  if (( ${#binaries} == 1 )); then
    cp $binaries[1]/$product $target
  else
    lipo -create ${^binaries}/$product -output $target
  fi
  chmod 755 $target
}

rm -rf $app
extension=$app/Contents/PlugIns/FlectFinder.appex
mkdir -p $app/Contents/{MacOS,Helpers,Resources/deps} $extension/Contents/{MacOS,Resources}

fill() {
  sed -e "s/__NAME__/$name/g" -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" \
      -e "s/__BUNDLE_ID__/$bundle_id/g" -e "s:__REPOSITORY__:$repository:g" $1 > $2
}
fill $package/Resources/App/Info.plist $app/Contents/Info.plist
fill $package/Resources/Finder/Info.plist $extension/Contents/Info.plist
combine Flect $app/Contents/MacOS/Flect
combine FlectFinder $extension/Contents/MacOS/FlectFinder

mkdir -p $work
icon_source=$repo_root/src/Web/assets/Flect.png
if [[ ! -f $work/AppIcon.icns || $icon_source -nt $work/AppIcon.icns ]]; then
  iconset=$work/AppIcon.iconset
  rm -rf $iconset
  mkdir -p $iconset
  for size in 16 32 128 256 512; do
    sips -z $size $size $icon_source --out $iconset/icon_${size}x${size}.png >/dev/null
    sips -z $((size * 2)) $((size * 2)) $icon_source --out $iconset/icon_${size}x${size}@2x.png >/dev/null
  done
  iconutil -c icns $iconset -o $work/AppIcon.icns
  sips -z 16 16 $icon_source --out $work/MenuIcon.png >/dev/null
  sips -z 32 32 $icon_source --out $work/MenuIcon@2x.png >/dev/null
fi
cp $work/AppIcon.icns $app/Contents/Resources/AppIcon.icns
cp $work/MenuIcon.png $work/MenuIcon@2x.png $extension/Contents/Resources/

cp $repo_root/LICENSE $app/Contents/Resources/LICENSE
cp $repo_root/NOTICES.md $app/Contents/Resources/NOTICES.md
cp $package/NOTICES.Mac.md $app/Contents/Resources/NOTICES.Mac.md
cp $repo_root/deps/subtitles.py $app/Contents/Resources/deps/subtitles.py

missing=()
for tool in ffmpeg ffprobe; do
  slices=()
  for arch in $archs; do
    [[ -x $deps/$arch/$tool ]] && slices+=($deps/$arch/$tool)
  done
  if (( ${#slices} == 1 && ${#archs} == 1 )); then
    cp $slices[1] $app/Contents/Helpers/$tool
  elif (( ${#slices} == ${#archs} )); then
    lipo -create $slices -output $app/Contents/Helpers/$tool
  else
    missing+=($tool)
  fi
done
if [[ -f $deps/cfr.jar ]]; then
  cp $deps/cfr.jar $app/Contents/Resources/deps/cfr.jar
else
  missing+=(cfr.jar)
fi

runtime=()
[[ $identity != "-" ]] && runtime=(--options runtime --timestamp)
for tool in $app/Contents/Helpers/*(N); do
  codesign --force --sign $identity $runtime $tool
done
codesign --force --sign $identity $runtime --entitlements $package/Resources/Finder/Finder.entitlements $extension
codesign --force --sign $identity $runtime $app
codesign --verify --deep --strict $app

echo "Built $app"
if (( ${#missing} )); then
  echo "Not bundled: ${missing[*]} - run scripts/mac/fetch.sh first. Flect falls back to Homebrew copies if present."
fi
