#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
[[ $# == 2 ]] || die 'usage: verify_pair.sh <release-directory> <managed-flutter-sdk>'
assert_host
require_commands python3
RELEASE=$(realpath "$1")
SDK=$(realpath "$2")
python3 "$WP1_REPO/engine/scripts/artifacts.py" validate "$RELEASE"
# Only a pipeline-managed SDK may be initialized or used for the test build.
[[ $SDK == "$WP1_CACHE"/flutter-* ]] || die 'pairing requires a managed SDK'
mkdir -p "$WP1_HOME/pair-verification"
WORK=$(mktemp -d "$WP1_HOME/pair-verification/verify.XXXXXXXX")
env -u FLUTTER_STORAGE_BASE_URL "$SDK/bin/flutter" --suppress-analytics precache --android
"$SDK/bin/flutter" --suppress-analytics --version --machine > "$WORK/flutter-version.json"
python3 - "$RELEASE/engine.manifest.json" "$WORK/flutter-version.json" <<'PY'
import json, sys
manifest, sdk = (json.load(open(path)) for path in sys.argv[1:])
assert manifest['flutter_version'] == sdk['frameworkVersion'], 'Flutter version mismatch'
assert manifest['engine_commit'] == sdk['engineRevision'], 'engine revision mismatch'
PY
cp "$WP1_REPO/engine/fixtures/pair/main.dart" "$WORK/main.dart"
printf '{"configVersion":2,"packages":[]}\n' > "$WORK/package_config.json"
"$SDK/bin/cache/dart-sdk/bin/dartaotruntime" \
  "$SDK/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot" \
  --sdk-root "$SDK/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/" \
  --target flutter --target-os android --aot --tfa \
  --packages "$WORK/package_config.json" --output-dill "$WORK/main.dill" "$WORK/main.dart"
[[ -s $WORK/main.dill ]] || die 'minimal kernel not produced'
"$RELEASE/gen_snapshot-linux-x64" --version
"$RELEASE/gen_snapshot-linux-x64" --snapshot_kind=app-aot-elf --elf="$WORK/libapp.so" "$WORK/main.dill"
[[ -s $WORK/libapp.so ]] || die 'minimal AOT snapshot not produced'
python3 "$WP1_REPO/engine/scripts/pair_device.py" "$RELEASE" "$SDK" "$WORK"
python3 "$WP1_REPO/engine/scripts/artifacts.py" validate "$RELEASE"
