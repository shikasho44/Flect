#!/bin/zsh
# Wraps dist/mac/Flect.app into a disk image, like scripts/package.ps1 does with Inno Setup.
#
#   scripts/mac/package.sh
#   FLECT_NOTARY_PROFILE=flect scripts/mac/package.sh     # also notarize and staple
#
# Notarization needs a Developer ID signature (FLECT_SIGNING_IDENTITY in build.sh) and a profile
# stored once with: xcrun notarytool store-credentials flect --apple-id … --team-id …

set -euo pipefail

repo_root=${0:A:h:h:h}
app=$repo_root/dist/mac/Flect.app
[[ -d $app ]] || { echo "Run scripts/mac/build.sh first." >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $app/Contents/Info.plist)
archs=$(lipo -archs $app/Contents/MacOS/Flect | tr ' ' '-')
image=$repo_root/dist/mac/Flect-$version-mac-$archs.dmg
staging=$repo_root/build/mac/dmg

rm -rf $staging $image
mkdir -p $staging
ditto $app $staging/Flect.app
ln -s /Applications $staging/Applications
hdiutil create -volname "Flect $version" -srcfolder $staging -ov -format UDZO $image >/dev/null
rm -rf $staging

if [[ -n ${FLECT_NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit $image --keychain-profile $FLECT_NOTARY_PROFILE --wait
  xcrun stapler staple $image
fi

shasum -a 256 $image
echo "Packaged $image"
