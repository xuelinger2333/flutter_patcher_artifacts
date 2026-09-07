#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
[[ $# == 1 ]] || die 'usage: resolve_engine.sh <flutter-version>'
assert_host
assert_version "$1"
require_commands git python3
VERSION=$1
SDK="$WP1_CACHE/flutter-$VERSION"
mkdir -p "$WP1_CACHE"
if [[ ! -d $SDK ]]; then
  git clone --depth 1 --branch "$VERSION" https://github.com/flutter/flutter.git "$SDK" >&2
fi
[[ $(git -C "$SDK" remote get-url origin) == https://github.com/flutter/flutter.git ]] || die 'unexpected Flutter source remote'
[[ -z $(git -C "$SDK" status --porcelain --untracked-files=no) ]] || die 'managed Flutter SDK has tracked edits'
git -C "$SDK" fetch --depth 1 origin "refs/tags/$VERSION" >&2
TAG_COMMIT=$(git -C "$SDK" rev-parse FETCH_HEAD)
git -C "$SDK" checkout --detach "$TAG_COMMIT" >&2
assert_commit "$SDK" "$TAG_COMMIT"
COMMIT=$(cat "$SDK/bin/internal/engine.version")
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || die 'invalid engine.version'
STAMP=$COMMIT
if [[ -f $SDK/bin/cache/engine.stamp ]]; then
  STAMP=$(cat "$SDK/bin/cache/engine.stamp")
fi
[[ $STAMP =~ ^[0-9a-f]{40}$ ]] || die 'invalid engine.stamp'
python3 - "$VERSION" "$COMMIT" "$STAMP" "$SDK" "$TAG_COMMIT" <<'PY'
import json, sys
print(json.dumps(dict(zip(('flutter_version', 'engine_commit', 'engine_stamp',
                          'flutter_sdk', 'framework_commit'), sys.argv[1:]))))
PY
