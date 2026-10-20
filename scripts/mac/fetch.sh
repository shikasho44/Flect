#!/bin/zsh
# Fetches the third-party tools that ship inside Flect.app, like scripts/fetch.ps1 does for Windows.
#
#   ffmpeg, ffprobe   built from the official source releases by build-ffmpeg.sh (about ten minutes)
#   cfr.jar           downloaded from the CFR releases on GitHub, checked against a pinned SHA-256
#
# Everything lands in dependencies/mac/. Re-running skips whatever is already present.
#   scripts/mac/fetch.sh            # this Mac's architecture
#   FLECT_ARCHS="arm64 x86_64" scripts/mac/fetch.sh
#   scripts/mac/fetch.sh --force    # rebuild everything

set -euo pipefail

repo_root=${0:A:h:h:h}
destination=${FLECT_DEPS:-$repo_root/dependencies/mac}
archs=(${=FLECT_ARCHS:-$(uname -m)})
force=false
[[ ${1:-} == --force ]] && force=true

cfr_url=https://github.com/leibnitz27/cfr/releases/download/0.152/cfr-0.152.jar
cfr_sha=f686e8f3ded377d7bc87d216a90e9e9512df4156e75b06c655a16648ae8765b2

mkdir -p $destination
echo "Fetching into $destination"

if $force || [[ ! -f $destination/cfr.jar ]]; then
  echo "  Downloading cfr 0.152"
  curl -fsSL --retry 3 -o $destination/cfr.jar.part $cfr_url
  actual=$(shasum -a 256 $destination/cfr.jar.part | awk '{print $1}')
  if [[ $actual != $cfr_sha ]]; then
    rm -f $destination/cfr.jar.part
    echo "Checksum mismatch for cfr.jar ($actual)" >&2
    exit 1
  fi
  mv $destination/cfr.jar.part $destination/cfr.jar
else
  echo "  cfr.jar already present"
fi

for arch in $archs; do
  if $force || [[ ! -x $destination/$arch/ffmpeg || ! -x $destination/$arch/ffprobe ]]; then
    FLECT_ARCH=$arch FLECT_DEPS=$destination ${0:A:h}/build-ffmpeg.sh
  else
    echo "  ffmpeg ($arch) already present"
  fi
done

echo "Done."
