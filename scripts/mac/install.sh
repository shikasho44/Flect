#!/bin/zsh
# Copies dist/mac/Flect.app into ~/Applications for local testing and turns its Finder menu on.
#
#   scripts/mac/install.sh
#   scripts/mac/install.sh --uninstall

set -euo pipefail

repo_root=${0:A:h:h:h}
source=$repo_root/dist/mac/Flect.app
target=${FLECT_INSTALL_DIR:-$HOME/Applications}/Flect.app
identifier=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" $source/Contents/Info.plist 2>/dev/null || echo io.github.shikasho44.flect)
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ ${1:-} == --uninstall ]]; then
  pluginkit -e ignore -i $identifier.finder 2>/dev/null || true
  [[ -d $target ]] && $lsregister -u $target
  pkill -f "Flect.app/Contents/PlugIns/FlectFinder.appex" 2>/dev/null || true
  if [[ -d $target ]]; then
    mv $target ~/.Trash/Flect-$(date +%Y%m%d%H%M%S).app
    echo "Moved $target to the Trash."
  fi
  exit 0
fi

[[ -d $source ]] || { echo "Run scripts/mac/build.sh first." >&2; exit 1; }
pkill -x Flect 2>/dev/null || true
pkill -f "Flect.app/Contents/PlugIns/FlectFinder.appex" 2>/dev/null || true
mkdir -p ${target:h}
# A copy left registered (in the Trash, or the build output) can still be picked to open flect:// links.
if [[ -d $target ]]; then
  $lsregister -u $target
  mv $target ~/.Trash/Flect-$(date +%Y%m%d%H%M%S).app
fi
ditto $source $target
$lsregister -u $source 2>/dev/null || true
$lsregister -f -R $target
pluginkit -a $target/Contents/PlugIns/FlectFinder.appex
pluginkit -e use -i $identifier.finder
echo "Installed $target"
pluginkit -m -i $identifier.finder
