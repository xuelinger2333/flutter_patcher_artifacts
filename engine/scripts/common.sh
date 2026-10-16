#!/usr/bin/env bash
set -euo pipefail
BUILDER_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
FLUTTER_PATCHER_ENGINE_HOME=${FLUTTER_PATCHER_ENGINE_HOME:-"$HOME/.flutter_patcher/engine-builder"}
ENGINE_CACHE="$FLUTTER_PATCHER_ENGINE_HOME/cache"
ENGINE_CHECKOUT="$ENGINE_CACHE/engine"
DEPOT_TOOLS_DIR="$ENGINE_CACHE/depot_tools"
ENGINE_SRC="$ENGINE_CHECKOUT/engine/src"
export DEPOT_TOOLS_UPDATE=0
# Primary host identity; secondary hosts use host_snapshot.py.
BUILD_HOST=linux-x64
GEN_SNAPSHOT="gen_snapshot-$BUILD_HOST"
SDK_TOOLCHAIN="bin/cache/artifacts/engine/$BUILD_HOST"

die() { printf 'ASSERTION_FAILED: %s\n' "$*" >&2; exit 1; }
assert_host() {
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'requires Linux x86_64'
  [[ $FLUTTER_PATCHER_ENGINE_HOME == /* ]] || die 'FLUTTER_PATCHER_ENGINE_HOME must be an absolute managed directory'
}
assert_commit() {
  [[ $2 =~ ^[0-9a-f]{40}$ ]] || die 'commit must be 40 lowercase hexadecimal digits'
  [[ $(git -C "$1" rev-parse HEAD) == "$2" ]] || die "checkout commit mismatch: $1"
}
assert_gn() {
  [[ -f $1 ]] || die 'args.gn missing'
  grep -Eq '^dart_dynamic_modules = true$' "$1" || die 'dart_dynamic_modules is not true'
}
assert_version() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid Flutter stable version'
  grep -Fxq "$1" "$BUILDER_REPO/supported_versions.txt" || die "unsupported Flutter version: $1"
}
assert_abi() { [[ $1 == arm64-v8a ]] || die 'only arm64-v8a is supported'; }
assert_clean_builder() {
  [[ -z $(git -C "$BUILDER_REPO" status --porcelain) ]] || die 'builder repository is dirty'
}
require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null || die "required command missing: $command"
  done
}
patch_digest() {
  python3 "$BUILDER_REPO/engine/scripts/source_state.py" patches "$BUILDER_REPO"
}
