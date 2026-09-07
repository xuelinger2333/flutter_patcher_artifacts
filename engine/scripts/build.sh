#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
[[ $# -ge 1 ]] || die 'usage: build.sh <flutter-version> [arm64-v8a] [--out <directory>]'
VERSION=$1
shift
ABI=arm64-v8a
if [[ $# -gt 0 && $1 != --out ]]; then ABI=$1; shift; fi
OUTPUT=''
if [[ $# -gt 0 ]]; then
  [[ $# == 2 && $1 == --out ]] || die 'only --out <directory> is accepted'
  OUTPUT=$(realpath -m "$2")
fi
assert_host
assert_version "$VERSION"
assert_abi "$ABI"
assert_clean_builder
require_commands python3 git flock zstd tee
[[ -x /usr/bin/time ]] || die 'GNU time is required'
mkdir -p "$WP1_HOME"
WP1_HOME=$(realpath "$WP1_HOME")
export WP1_HOME
# This also serializes manual builds sharing a cache with the Actions runner.
exec 9> "$WP1_HOME/build.lock"
flock --exclusive 9
RUN_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
RUN="$WP1_HOME/runs/$RUN_ID"
mkdir -p "$RUN"
OUTPUT=${OUTPUT:-"$RUN/release"}
[[ ! -e $OUTPUT ]] || die "output already exists: $OUTPUT"
exec 3>&1 4>&2
exec > >(tee "$RUN/build.log") 2>&1
LOGGER=$!
finish() {
  local status=$?
  trap - EXIT
  exec 1>&3 2>&4
  if ! wait "$LOGGER"; then status=1; fi
  mkdir -p "$OUTPUT"
  if ! zstd --quiet --stdout "$RUN/build.log" > "$OUTPUT/build.log.zst"; then status=1; fi
  if [[ $status == 0 ]]; then
    if ! python3 "$WP1_REPO/engine/scripts/artifacts.py" validate "$OUTPUT" --publishable; then status=1; fi
  fi
  printf '%s\n' "$status" > "$RUN/exit-code.txt"
  if [[ $status == 0 ]]; then
    printf 'ENGINE_RELEASE_READY: %s\n' "$OUTPUT"
  else
    printf 'ENGINE_BUILD_FAILED: logs in %s\n' "$RUN" >&2
  fi
  exit "$status"
}
trap finish EXIT
printf 'Build %s: Flutter %s, ABI %s, builder %s\n' "$RUN_ID" "$VERSION" "$ABI" "$(git -C "$WP1_REPO" rev-parse HEAD)"
date -u +%FT%TZ
bash "$WP1_REPO/engine/scripts/resolve_engine.sh" "$VERSION" > "$RUN/resolved.json"
COMMIT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["engine_commit"])' "$RUN/resolved.json")
/usr/bin/time -v -o "$RUN/sync.time" bash "$WP1_REPO/engine/scripts/fetch_engine.sh" "$COMMIT"
/usr/bin/time -v -o "$RUN/build.time" bash "$WP1_REPO/engine/scripts/build_android.sh" "$ABI" "$RUN/resolved.json" "$RUN/identity.json"
bash "$WP1_REPO/engine/scripts/package.sh" "$RUN/identity.json" "$OUTPUT"
bash "$WP1_REPO/engine/scripts/verify_pair.sh" "$OUTPUT" "$WP1_CACHE/flutter-$VERSION"
cp "$OUTPUT/engine.manifest.json" "$RUN/manifest.build.json"
date -u +%FT%TZ
echo 'Build and verification completed; compressing full log.'
