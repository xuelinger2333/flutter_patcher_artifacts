#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
[[ $# == 3 ]] || die 'usage: build_android.sh <abi> <resolved.json> <identity.json>'
assert_host
assert_abi "$1"
assert_clean_builder
RESOLVED=$(realpath "$2")
IDENTITY=$(realpath -m "$3")
COMMIT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["engine_commit"])' "$RESOLVED")
assert_commit "$WP1_ENGINE" "$COMMIT"
assert_commit "$WP1_DEPOT" "$(cat "$WP1_REPO/DEPOT_TOOLS_REV")"
export PATH="$WP1_DEPOT:$PATH"
require_commands ninja python3
python3 "$WP1_REPO/engine/scripts/source_state.py" check-clean "$WP1_ENGINE"
[[ ! -e $WP1_CACHE/applied.patch ]] || die 'fetch_engine must prepare an unpatched checkout'
DART="$WP1_SRC/flutter/third_party/dart"
PATCHES=("$WP1_REPO"/engine_patches/*.patch)
[[ -f ${PATCHES[0]} ]] || die 'no engine patches'
git -C "$DART" apply --check "${PATCHES[@]}"
git -C "$DART" apply "${PATCHES[@]}"
git -C "$DART" diff --full-index --binary HEAD > "$WP1_CACHE/applied.patch"
[[ -s $WP1_CACHE/applied.patch ]] || die 'engine patches made no changes'
cd "$WP1_SRC"
# Fixed recipe and targets established by T-1; no workflow GN flag overrides.
./flutter/tools/gn --android --android-cpu arm64 --runtime-mode release \
  --no-prebuilt-dart-sdk --dart-dynamic-modules
OUT=out/android_release_arm64
assert_gn "$OUT/args.gn"
TARGETS=$(flutter/third_party/gn/gn ls "$OUT" '//flutter/shell/platform/android:*')
grep -Fxq '//flutter/shell/platform/android:android_jar' <<< "$TARGETS" || die 'android_jar GN target missing'
TARGETS=$(flutter/third_party/gn/gn ls "$OUT" '//flutter/lib/snapshot:*')
grep -Fxq '//flutter/lib/snapshot:generate_snapshot_bin' <<< "$TARGETS" || die 'snapshot GN target missing'
ninja -C "$OUT" -j8 flutter/shell/platform/android:android_jar clang_x64/gen_snapshot
for FILE in libflutter.so lib.stripped/libflutter.so flutter_embedding_release.jar clang_x64/gen_snapshot; do
  [[ -s $OUT/$FILE ]] || die "build artifact missing: $FILE"
done
[[ -x $OUT/clang_x64/gen_snapshot ]] || die 'gen_snapshot is not executable'
"$OUT/clang_x64/gen_snapshot" --version
assert_commit "$WP1_ENGINE" "$COMMIT"
assert_commit "$WP1_DEPOT" "$(cat "$WP1_REPO/DEPOT_TOOLS_REV")"
git -C "$DART" diff --full-index --binary HEAD > "$WP1_CACHE/current.patch"
cmp "$WP1_CACHE/applied.patch" "$WP1_CACHE/current.patch" || die 'source patch changed during build'
rm -- "$WP1_CACHE/current.patch"
python3 "$WP1_REPO/engine/scripts/source_state.py" record-build \
  "$WP1_REPO" "$WP1_ENGINE" "$RESOLVED" "$IDENTITY"
