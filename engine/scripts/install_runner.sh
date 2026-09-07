#!/usr/bin/env bash
# Provision a replaceable Linux runner. Registration token is read from stdin.
source "$(dirname -- "$0")/common.sh"
[[ $# == 2 ]] || die 'usage: install_runner.sh <owner/repository> <runner-name>'
assert_host
require_commands curl tar sha256sum
[[ $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'invalid repository'
[[ $2 =~ ^[A-Za-z0-9_.-]+$ ]] || die 'invalid runner name'
RUNNER="$WP1_HOME/actions-runner"
[[ ! -e $RUNNER ]] || die 'runner directory already exists'
mkdir -p "$RUNNER"
cd "$RUNNER"
VERSION=2.337.0
ARCHIVE="actions-runner-linux-x64-$VERSION.tar.gz"
curl --fail --location --output "$ARCHIVE" \
  "https://github.com/actions/runner/releases/download/v$VERSION/$ARCHIVE"
printf '%s  %s\n' 70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613 "$ARCHIVE" | sha256sum --check
tar -xzf "$ARCHIVE"
IFS= read -r REGISTRATION_TOKEN
REGISTRATION_TOKEN=${REGISTRATION_TOKEN%$'\r'}
[[ -n $REGISTRATION_TOKEN ]] || die 'registration token missing on stdin'
if [[ $(id -u) == 0 ]]; then
  export RUNNER_ALLOW_RUNASROOT=1
fi
./config.sh --unattended --url "https://github.com/$1" --token "$REGISTRATION_TOKEN" \
  --name "$2" --labels engine-builder --work _work --disableupdate
unset REGISTRATION_TOKEN
printf 'Runner configured in %s. Install its service with ./svc.sh install <user> and ./svc.sh start.\n' "$RUNNER"
