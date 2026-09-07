#!/usr/bin/env bash
set -euo pipefail
WP1_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WP1_HOME=${WP1_HOME:-"$HOME/.flutter_patcher/engine-builder"}
WP1_CACHE="$WP1_HOME/cache"
WP1_ENGINE="$WP1_CACHE/engine"
WP1_DEPOT="$WP1_CACHE/depot_tools"
WP1_SRC="$WP1_ENGINE/engine/src"
export DEPOT_TOOLS_UPDATE=0

die() { printf 'WP1_ASSERTION_FAILED: %s\n' "$*" >&2; exit 1; }
assert_host() {
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'requires Linux x86_64'
  [[ $WP1_HOME == /* ]] || die 'WP1_HOME must be an absolute managed directory'
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
  grep -Fxq "$1" "$WP1_REPO/supported_versions.txt" || die "unsupported Flutter version: $1"
}
assert_abi() { [[ $1 == arm64-v8a ]] || die 'M1 supports only arm64-v8a'; }
assert_clean_builder() {
  [[ -z $(git -C "$WP1_REPO" status --porcelain) ]] || die 'builder repository is dirty'
}
require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null || die "required command missing: $command"
  done
}
patch_digest() {
  python3 "$WP1_REPO/engine/scripts/source_state.py" patches "$WP1_REPO"
}
