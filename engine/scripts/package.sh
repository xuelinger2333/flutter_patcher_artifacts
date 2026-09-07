#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
[[ $# == 2 ]] || die 'usage: package.sh <identity.json> <release-directory>'
assert_clean_builder
python3 "$WP1_REPO/engine/scripts/artifacts.py" package \
  --build-dir "$WP1_SRC/out/android_release_arm64" --identity "$1" --out "$2"
