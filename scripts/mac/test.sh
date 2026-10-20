#!/bin/zsh
# Runs the macOS evaluation suite (the counterpart of evals/Evals on Windows).
#
#   scripts/mac/test.sh                  # everything that needs no extra permission
#   scripts/mac/test.sh --speech         # also transcribe speech with Apple Speech
#   scripts/mac/test.sh Image Video      # only cases whose name contains a word
#
# Fixtures are generated into a temporary folder; ffmpeg comes from dependencies/mac (scripts/mac/fetch.sh).

set -euo pipefail

# Hides build chatter, but shows it when the command fails.
quiet() {
  local log
  log=$(mktemp)
  if ! "$@" >$log 2>&1; then cat $log >&2; rm -f $log; return 1; fi
  rm -f $log
}

repo_root=${0:A:h:h:h}
package=$repo_root/src/Mac
export CLANG_MODULE_CACHE_PATH=$package/.build/clang-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=$package/.build/swiftpm-module-cache
export FLECT_DEPS=${FLECT_DEPS:-$repo_root/dependencies/mac}

quiet swift build --package-path $package --disable-sandbox -c release --product FlectEvals
$(swift build --package-path $package --disable-sandbox -c release --show-bin-path)/FlectEvals "$@"
