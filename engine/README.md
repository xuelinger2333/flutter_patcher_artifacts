# Engine build sources

## Host matrix

`gen_snapshot` is a host-native tool, so each supported build host needs its own
binary from the same patched engine source. The release carries one
`libflutter.so`/embedding jar pair and one `gen_snapshot` per host under a single
`build_id` (manifest schema 2, below).

| Host | Role | Asset | Pipeline |
|---|---|---|---|
| linux-x64 | primary: engine, embedding jar, `gen_snapshot` | `gen_snapshot-linux-x64` | `engine/scripts/build.sh` (bash) |
| windows-x64 | secondary: `gen_snapshot` only | `gen_snapshot-windows-x64.exe` | `engine/scripts/host_snapshot.py` |
| macos-arm64 | secondary, implemented but no runner or acceptance yet | `gen_snapshot-darwin-arm64` | `engine/scripts/host_snapshot.py` |

Secondary hosts never build `libflutter.so`; their `gen_snapshot` is bound to the
primary release by identical `engine_commit`, `engine_stamp`, `depot_tools_rev`
and patch digests, checked by `artifacts.py attach`. The snapshot format is a
property of the Dart source, not of the host compiler, which is also how the
stock Flutter SDK pairs a Linux-built engine with a Windows-built
`gen_snapshot.exe`.

## Primary host (linux-x64)

Maintainer build environment: Linux x86_64, Android arm64-v8a release target;
Git, Python 3, pinned depot_tools, GN/Ninja, flock, zstd, GNU time, and the Flutter
engine's system prerequisites. `DEPOT_TOOLS_REV` is fixed at repository root.
Use a dedicated managed directory, never a user's Flutter SDK or application.

The build workflow invokes `engine/scripts/build.sh`, which resolves the engine,
fetches dependencies, verifies and applies patches, builds fixed targets, packages
the artifacts, then verifies the engine/gen_snapshot pair. Both are bound by one
`build_id` in `engine.manifest.json`. The embedding jar is copied unchanged.

## Secondary hosts (windows-x64, macos-arm64)

`engine/scripts/host_snapshot.py` is the Python counterpart of the bash pipeline
for hosts that only add a `gen_snapshot`. Same managed layout under `FLUTTER_PATCHER_ENGINE_HOME`
(`cache/depot_tools`, `cache/engine`, `cache/flutter-<version>`, `runs/<id>`), same
pinned depot_tools, same GN recipe (`--android --android-cpu arm64 --runtime-mode
release --no-prebuilt-dart-sdk --dart-dynamic-modules`), same patch bookkeeping
(`cache/applied.patch`). Only the Ninja target differs: Windows builds
`flutter:gen_snapshot`, which copies the host-toolchain binary to
`out/android_release_arm64/gen_snapshot/gen_snapshot.exe`.

```text
python engine/scripts/host_snapshot.py fetch  3.47.2                 # checkout only
python engine/scripts/host_snapshot.py build  3.47.2 --out <bundle>  # fetch, patch, build, verify snapshot
python engine/scripts/host_snapshot.py attach <release> <bundle>     # merge; device pairing when a device is attached
```

`build` writes a bundle: the binary plus `host.manifest.json` (`kind:
host_snapshot`), whose `verify.snapshot` is set only after the bundle's own
`gen_snapshot` compiled the pairing fixture to an arm64 ELF with the managed
stock SDK. `attach` copies the binary into a release, appends its record, and
runs `pair_device.py` on the attaching host: the fixture snapshot compiled by the
new `gen_snapshot` is installed with the primary `libflutter.so` on a connected
device, or recorded `device: skipped / no_android_device`.

Windows prerequisites, checked by `install_runner.ps1` and the pipeline itself:

- Visual Studio 2026 or 2022 with "Desktop development with C++" and a Windows
  10/11 SDK. The pipeline sets `DEPOT_TOOLS_WIN_TOOLCHAIN=0`, `GYP_MSVS_VERSION`
  and `GYP_MSVS_OVERRIDE_PATH` itself (also for the `Insiders` product folder
  the upstream detection does not know); the toolset is recorded in the
  manifest record's `toolchain` field.
- Git and a CPython 3 on PATH (not the Microsoft Store alias). depot_tools
  bootstraps its own CPython through `bootstrap\win_tools.bat`; `gclient`,
  hooks and `flutter/tools/gn` use that one.
- A short `FLUTTER_PATCHER_ENGINE_HOME` such as `D:\fpe` (24 characters at most) so the engine
  checkout stays under `MAX_PATH`; the pipeline additionally runs every git
  with `core.longpaths=true`, `core.autocrlf=false` and `core.filemode=false`
  through `GIT_CONFIG_*` environment variables, without touching user config.
- No Android NDK or SDK: DEPS only downloads Android dependencies on Linux and
  macOS hosts, and the gen_snapshot target does not need them.

Disk footprint (Windows, 3.47.2): engine checkout with `--no-history` about
20 GB, build output about 2 GB, managed stock SDK with Android cache about 1 GB.
Everything lives under `FLUTTER_PATCHER_ENGINE_HOME`; deleting that directory removes all of it.

## Manifest schema 2

`engine.manifest.json` schema 2 differs from schema 1 only in `files`:

- `gen_snapshot` records may appear once per host, keyed by `host_os`
  (`linux`, `windows`, `macos`) and `host_arch` (`x64`, `arm64`); the name is
  `gen_snapshot-<sdk toolchain dir>[.exe]`, so macOS spells `darwin-arm64`.
- every `gen_snapshot` record carries its own `verify` (`snapshot`, `device`,
  `device_reason`), `built_at`, `builder_repo_commit` and an optional
  `toolchain` map of strings.
- the release-level `verify` keeps its schema 1 meaning: the primary host's
  pairing result.

`artifacts.py validate --publishable` requires every host record to have passed
or skipped device verification. Schema 1 releases remain valid input to
`validate` and to `attach`, which upgrades them in place (same `build_id`, same
bytes for the existing assets). The CLI reads both schemas, downloads only the
record for its own host, and caches engine artifacts per host.

## Resource footprint (linux-x64)

| Measurement | Value |
|---|---|
| Build host CPU / memory / filesystem | Linux x64; 8 CPUs; 16,773,283,840 B RAM; 539,792,977,920 B filesystem |
| Initial fetch/sync and build duration | 216.62 s fetch/sync; 1,026.50 s build stage including GN and checks; Ninja itself 1,024.902 s with -j8 |
| Runner cgroup memory.peak | 12,234,321,920 B, including charged file cache, service lifetime through first build verification; not aggregate peak RSS |
| Checkout / output apparent size after build | 26,843,462,179 B / 1,367,516,597 B (`du -sb`) |
| Engine jar / gen_snapshot / embedding jar size | 11,908,360 B / 6,295,056 B / 1,584,072 B |

Two builds of the same source produce identical artifact hashes; a rebuild with a
warm cache takes about 18 s sync and 233 s build stage.
Build logs stay on the runner; the publisher does not upload them as Release assets.

No user-facing source-build fallback is provided. Runner provisioning is a
maintainer operation performed by the user after review: `install_runner.sh`
(Linux) or `install_runner.ps1` (Windows).
