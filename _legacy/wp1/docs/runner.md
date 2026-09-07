# Replacing the Linux builder

The server is disposable. Source, patches, build configuration, tests, and
release code come from this repository. Do not restore /opt/engine experiments
or copy an old server's binaries into a release directory.

## Tested operating system

T-1 uses Debian 13 x86_64, eight available CPU threads, OpenJDK 21, Python 3.13,
and a local filesystem. See README.md for measured memory/disk/time values;
they are observations, not invented minimum requirements.

Install Git, Python 3, curl, unzip, zip, zstd, GNU time, pkg-config, a C/C++ build
environment, and a JDK. The engine's DEPS and hooks download the pinned compiler,
Android native toolchain, GN, and sysroots. The build scripts clone their own
depot_tools, Flutter SDK, and engine source. They do not use a preexisting Flutter
installation or experimental engine checkout.

For the GitHub runner on Debian 13, the actual missing packages were libicu76
and liblttng-ust1t64 (with its dependencies). libkrb5-3, zlib1g, and libssl3t64
were already installed. The upstream runner's bin/installdependencies.sh lists
equivalents for other distributions. Install the proper packages rather than
disabling .NET globalization or bypassing its dependency checks.

For device verification, additionally install Android SDK platform/build tools,
make adb and keytool available, and set ANDROID_SDK_ROOT. No attached device is
a supported skipped result; an attached incompatible or failing device is not.

## Persistent state

Default WP1_HOME is ~/.flutter_patcher/engine-builder. It contains:

- cache/depot_tools: exact DEPOT_TOOLS_REV, automatic updates disabled.
- cache/flutter-<version>: managed official SDK for resolving versions and tests.
- cache/engine: persistent monorepo + DEPS checkouts and Android build output.
- cache/applied.patch: exact full-index diff last applied by this pipeline.
- runs/: logs and build provenance, separate from the checkout and artifacts.
- pair-verification/: isolated temporary apps and snapshots for each verification.
- actions-runner/: optional dedicated Actions runner installation.

Set the GitHub repository variable ENGINE_WORK_DIR only to an absolute dedicated
persistent directory owned by the runner account. A fresh server may omit it and
use the default. Never point it at a user SDK or application.

The first runner uses /root/.flutter_patcher/wp1 and label engine-builder. This
path is deployment configuration; source scripts do not hardcode it.

## Registration

1. Clone this repository at the commit to deploy.
2. Obtain a short-lived runner registration token for this GitHub repository.
3. Supply the token on stdin to `bash scripts/install_runner.sh owner/repository runner-name`.
   Do not store it in Git, command history, logs, or repository variables.
4. In the resulting actions-runner directory, install and start the service with
   `./svc.sh install <runner-user>` and `./svc.sh start` using appropriate privileges.
5. Confirm the runner is online with labels self-hosted, Linux, X64, engine-builder.

The installer pins Actions Runner 2.337.0 and verifies the downloaded archive's
SHA-256 before extraction. Automatic runner updates are disabled. Update the
version/hash explicitly and redeploy within GitHub's runner support window.

An interrupted installation leaves its directory for diagnosis. If the archive
was verified/extracted but registration failed because of missing prerequisites,
fix those prerequisites and run that directory's config.sh with a fresh token;
do not overwrite a registered runner or reuse an expired token.

## SSH is only transport

Sync committed code with Git or a Git bundle. Never edit production source only
on the builder. For a long manual invocation over SSH, use a detached service or
nohup with stdout/stderr redirected to a persistent file, then inspect its log
and exit status. T-1's first interactive SSH session was disconnected mid-build;
the interrupted output was preserved and a clean full measurement was restarted.

GitHub Actions runs under its service independently of the interactive SSH
session. Workflow concurrency and a local filesystem lock serialize builds.
