#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
[[ $# == 1 ]] || die 'usage: fetch_engine.sh <engine-commit>'
assert_host
[[ $1 =~ ^[0-9a-f]{40}$ ]] || die 'invalid engine commit'
COMMIT=$1
require_commands git python3
mkdir -p "$WP1_CACHE"
DEPOT_REV=$(cat "$WP1_REPO/DEPOT_TOOLS_REV")
[[ $DEPOT_REV =~ ^[0-9a-f]{40}$ ]] || die 'invalid DEPOT_TOOLS_REV'
if [[ ! -d $WP1_DEPOT ]]; then
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WP1_DEPOT"
fi
[[ $(git -C "$WP1_DEPOT" remote get-url origin) == https://chromium.googlesource.com/chromium/tools/depot_tools.git ]] || die 'unexpected depot_tools remote'
[[ -z $(git -C "$WP1_DEPOT" status --porcelain --untracked-files=no) ]] || die 'depot_tools has tracked edits'
git -C "$WP1_DEPOT" fetch origin "$DEPOT_REV"
git -C "$WP1_DEPOT" checkout --detach "$DEPOT_REV"
assert_commit "$WP1_DEPOT" "$DEPOT_REV"
export PATH="$WP1_DEPOT:$PATH"
if [[ ! -d $WP1_ENGINE ]]; then
  git init "$WP1_ENGINE"
  git -C "$WP1_ENGINE" remote add origin https://github.com/flutter/flutter.git
fi
[[ $(git -C "$WP1_ENGINE" remote get-url origin) == https://github.com/flutter/flutter.git ]] || die 'unexpected engine source remote'
# Only undo the exact patch applied by our previous successful preparation.
# Unknown edits stop the job; no reset --hard, clean -fd, or force is used.
PREVIOUS="$WP1_CACHE/applied.patch"
DART="$WP1_SRC/flutter/third_party/dart"
if [[ -f $PREVIOUS ]]; then
  [[ -d $DART/.git ]] || die 'recorded patched Dart checkout missing'
  git -C "$DART" diff --full-index --binary HEAD > "$WP1_CACHE/current.patch"
  cmp "$PREVIOUS" "$WP1_CACHE/current.patch" || die 'cached patch differs from recorded patch'
  git -C "$DART" apply --reverse --check "$PREVIOUS"
  git -C "$DART" apply --reverse "$PREVIOUS"
  rm -- "$PREVIOUS" "$WP1_CACHE/current.patch"
fi
if git -C "$WP1_ENGINE" rev-parse --verify HEAD >/dev/null 2>&1; then
  python3 "$WP1_REPO/engine/scripts/source_state.py" check-clean "$WP1_ENGINE"
fi
git -C "$WP1_ENGINE" fetch --depth 1 origin "$COMMIT"
git -C "$WP1_ENGINE" checkout --detach "$COMMIT"
assert_commit "$WP1_ENGINE" "$COMMIT"
cp "$WP1_ENGINE/engine/scripts/standard.gclient" "$WP1_ENGINE/.gclient"
cd "$WP1_ENGINE"
gclient sync -D --no-history
assert_commit "$WP1_ENGINE" "$COMMIT"
assert_commit "$WP1_DEPOT" "$DEPOT_REV"
python3 "$WP1_REPO/engine/scripts/source_state.py" check-clean "$WP1_ENGINE"
