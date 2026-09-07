#!/usr/bin/env bash
set -euo pipefail
ROOT=/root/.flutter_patcher/wp1
export WP1_HOME="$ROOT"
exec 9> "$ROOT/build.lock"
flock --exclusive 9
BENCH="$ROOT/incremental-2026-09-07"
mkdir "$BENCH"
exec > "$BENCH/benchmark.log" 2>&1
cp "$ROOT/incoming/previous-engine.json" "$BENCH/previous.json"
cp "$ROOT/t1/resolved.json" "$BENCH/current.json"
echo 'Preparing Flutter 3.47.1 engine baseline for the cross-commit measurement'
date -u +%FT%TZ
/usr/bin/time -v -o "$BENCH/previous-sync.time" bash "$ROOT/repository/scripts/fetch_engine.sh" 5d531788691ec3404cac0cee66ead4007b177363
/usr/bin/time -v -o "$BENCH/previous-build.time" bash "$ROOT/repository/scripts/build_android.sh" arm64-v8a "$BENCH/previous.json" "$BENCH/previous-identity.json"
echo 'Measured switch: Flutter 3.47.1 engine -> Flutter 3.47.2 engine'
date -u +%FT%TZ
/usr/bin/time -v -o "$BENCH/incremental-sync.time" bash "$ROOT/repository/scripts/fetch_engine.sh" a804b261645ef8c13eb3d5c44a5c2fb0340c5539
/usr/bin/time -v -o "$BENCH/incremental-build.time" bash "$ROOT/repository/scripts/build_android.sh" arm64-v8a "$BENCH/current.json" "$BENCH/current-identity.json"
python3 - "$ROOT/repro/final-first/manifest.json" "$BENCH/current-identity.json" <<'PY'
import json, sys
manifest, identity = (json.load(open(path)) for path in sys.argv[1:])
assert identity['engine_commit'] == manifest['engine_commit'], 'Current engine commit was not restored'
assert identity['patches'] == manifest['patches'], 'Current patch inputs were not restored'
PY
bash "$ROOT/repository/scripts/package.sh" "$BENCH/current-identity.json" "$BENCH/release"
bash "$ROOT/repository/scripts/verify_pair.sh" "$BENCH/release" "$ROOT/cache/flutter-3.47.2"
date -u +%FT%TZ
echo INCREMENTAL_BENCHMARK_PASSED
