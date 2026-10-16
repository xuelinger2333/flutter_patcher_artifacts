#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
[[ $# == 1 ]] || die 'usage: fetch_engine.sh <engine-commit>'
assert_host
[[ $1 =~ ^[0-9a-f]{40}$ ]] || die 'invalid engine commit'
COMMIT=$1
require_commands git python3
mkdir -p "$ENGINE_CACHE"
DEPOT_REV=$(cat "$BUILDER_REPO/DEPOT_TOOLS_REV")
[[ $DEPOT_REV =~ ^[0-9a-f]{40}$ ]] || die 'invalid DEPOT_TOOLS_REV'
if [[ ! -d $DEPOT_TOOLS_DIR ]]; then
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
fi
[[ $(git -C "$DEPOT_TOOLS_DIR" remote get-url origin) == https://chromium.googlesource.com/chromium/tools/depot_tools.git ]] || die 'unexpected depot_tools remote'
[[ -z $(git -C "$DEPOT_TOOLS_DIR" status --porcelain --untracked-files=no) ]] || die 'depot_tools has tracked edits'
git -C "$DEPOT_TOOLS_DIR" fetch origin "$DEPOT_REV"
git -C "$DEPOT_TOOLS_DIR" checkout --detach "$DEPOT_REV"
assert_commit "$DEPOT_TOOLS_DIR" "$DEPOT_REV"
export PATH="$DEPOT_TOOLS_DIR:$PATH"
if [[ ! -d $ENGINE_CHECKOUT ]]; then
  git init "$ENGINE_CHECKOUT"
  git -C "$ENGINE_CHECKOUT" remote add origin https://github.com/flutter/flutter.git
fi
[[ $(git -C "$ENGINE_CHECKOUT" remote get-url origin) == https://github.com/flutter/flutter.git ]] || die 'unexpected engine source remote'
# Only undo the exact patch applied by our previous successful preparation.
# Unknown edits stop the job; no reset --hard, clean -fd, or force is used.
PREVIOUS="$ENGINE_CACHE/applied.patch"
DART="$ENGINE_SRC/flutter/third_party/dart"
if [[ -f $PREVIOUS ]]; then
  [[ -d $DART/.git ]] || die 'recorded patched Dart checkout missing'
  git -C "$DART" diff --full-index --binary HEAD > "$ENGINE_CACHE/current.patch"
  cmp "$PREVIOUS" "$ENGINE_CACHE/current.patch" || die 'cached patch differs from recorded patch'
  git -C "$DART" apply --reverse --check "$PREVIOUS"
  git -C "$DART" apply --reverse "$PREVIOUS"
  rm -- "$PREVIOUS" "$ENGINE_CACHE/current.patch"
fi
if git -C "$ENGINE_CHECKOUT" rev-parse --verify HEAD >/dev/null 2>&1; then
  python3 "$BUILDER_REPO/engine/scripts/source_state.py" check-clean "$ENGINE_CHECKOUT"
fi
git -C "$ENGINE_CHECKOUT" fetch --depth 1 origin "$COMMIT"
git -C "$ENGINE_CHECKOUT" checkout --detach "$COMMIT"
assert_commit "$ENGINE_CHECKOUT" "$COMMIT"
cp "$ENGINE_CHECKOUT/engine/scripts/standard.gclient" "$ENGINE_CHECKOUT/.gclient"
cd "$ENGINE_CHECKOUT"
gclient sync -D --no-history
assert_commit "$ENGINE_CHECKOUT" "$COMMIT"
assert_commit "$DEPOT_TOOLS_DIR" "$DEPOT_REV"
python3 "$BUILDER_REPO/engine/scripts/source_state.py" check-clean "$ENGINE_CHECKOUT"
