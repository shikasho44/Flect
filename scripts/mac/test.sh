#!/bin/zsh
# Runs the macOS evaluation suite (the counterpart of evals/Evals on Windows).
#
#   scripts/mac/test.sh                  # everything that needs no extra permission
#   scripts/mac/test.sh --speech         # also transcribe speech with Apple Speech
#   scripts/mac/test.sh Image Video      # only cases whose name contains a word
#
# Fixtures are generated into a temporary folder; ffmpeg comes from dependencies/mac (scripts/mac/fetch.sh).

set -euo pipefail

repo_root=${0:A:h:h:h}
package=$repo_root/src/Mac
export CLANG_MODULE_CACHE_PATH=$package/.build/clang-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=$package/.build/swiftpm-module-cache
export FLECT_DEPS=${FLECT_DEPS:-$repo_root/dependencies/mac}

swift build --package-path $package --disable-sandbox -c release --product FlectEvals >/dev/null
$(swift build --package-path $package --disable-sandbox -c release --show-bin-path)/FlectEvals "$@"
