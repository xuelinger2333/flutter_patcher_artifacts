# flutter_patcher_engine

Reproducible source and release pipeline for the Android dynamic-module engine
used by flutter_patcher. This repository is the source of truth. Build machines
are replaceable: their checkouts, caches, and experimental changes are never
release inputs unless explicitly recorded here.

## WP-1 scope

- Build host: Linux x86_64. Target: Android arm64-v8a, release mode.
- Build the engine and Linux gen_snapshot together with dynamic modules enabled.
- Publish engine jars, gen_snapshot, manifest.json, and a compressed full log.
- Tool snapshots and interface YAML belong to flutter_patcher's WP-1b pipeline.
- CLI/doctor, runtime changes, other ABIs, and Windows/macOS hosts are outside WP-1.

## Development status

T-1 passed for Flutter 3.47.2: a fresh engine checkout produced the Android
engine, embedding, and Linux gen_snapshot; the minimal AOT snapshot compiled
successfully. Device verification was skipped because neither the builder nor
the development machine had an Android device attached. The manual build workflow
published [engine-3.47.2](https://github.com/xuelinger2333/flutter_patcher_engine/releases/tag/engine-3.47.2).
Two builds at the same builder commit passed manifest comparison, with identical
hashes for all three main artifacts. All five downloaded release attachments
passed hash verification. See [acceptance evidence](docs/acceptance.md).

Implementation follows flutter_patcher's plan/SPEC_M1.md rev2 (2026-09-07).
See [T-1](docs/T-1.md) for the measurement protocol and original evidence.

## Source and workspace ownership

Edit and commit release inputs in this repository before synchronizing to a
builder. A builder must use that exact commit, a pinned depot_tools revision,
the engine commit resolved from the selected Flutter tag, and the patches in
this repository. Existing experiments on a server may be inspected, but must
not be silently reused as official source or packaged as a fresh build.

Use a dedicated persistent build directory under ~/.flutter_patcher/ (or an
explicit --out directory), outside the Actions checkout. Do not change a user's
Flutter SDK or application. Never erase an unrelated checkout to prepare a job.

## Measured environment

Only actual measurements belong in this table; historical prototype timings
are not measurements of this pipeline.

| Measurement | Value |
| --- | --- |
| CPU / memory / disk | 8 threads / 16,773,283,840 bytes RAM / 539,792,977,920-byte filesystem |
| First gclient sync time | 3 min 39.05 s, new source checkout; existing machine download caches were not erased |
| Engine checkout and dependency size | 25,496,146,396 apparent bytes before compilation (`du -sb`) |
| Ninja elapsed time and parallelism | 16 min 23.40 s, `-j8`, clean output directory |
| out/android_release_arm64 size | 1,367,324,021 apparent bytes (`du -sb`) |
| Build peak memory | 8,387,522,560 bytes, dedicated cgroup v2 `memory.peak` (includes charged cache) |
| libflutter.so / embedding jar / gen_snapshot sizes | 11,908,208 / 1,584,072 / 6,295,056 bytes; SO is the stripped release file |
| Incremental build after changing commit | Flutter 3.47.1 engine → 3.47.2: dependency sync 28.45 s; build stage 6 min 15.91 s (`-j8`, includes GN and assertions) |

The complete successful T-1 log, manifest, source identities and raw measurements
are in [measurements/T1-2026-09-07](measurements/T1-2026-09-07/).
An earlier SSH-interrupted attempt is excluded from these complete-build timings.
The cross-commit measurement reused the existing output directory after a
successful 3.47.1 baseline build. Preparation time is recorded separately in
[measurements/incremental-2026-09-07](measurements/incremental-2026-09-07/);
3.47.1 was used only for measurement and is not a supported release.

## Build and validate

On a prepared Linux x64 machine (see [runner setup](docs/runner.md)):

```bash
git clone https://github.com/xuelinger2333/flutter_patcher_engine.git
cd flutter_patcher_engine
python3 -m unittest discover -s scripts/test -v
bash scripts/build.sh 3.47.2 arm64-v8a --out "$HOME/.flutter_patcher/releases/3.47.2-first"
```

The destination must not already exist. The build uses a persistent cache under
~/.flutter_patcher/engine-builder, protected by a filesystem lock. It resolves
the selected tag, synchronizes the pinned engine/DEPS, applies the checked-in
patches, builds fixed targets, packages, and verifies the pair. Failure returns
nonzero and preserves a compressed full log in the output directory.

Repeat at the same builder commit with a second output directory, then compare:

```bash
python3 scripts/artifacts.py validate /absolute/path/to/release --publishable
python3 scripts/artifacts.py compare /absolute/path/to/first /absolute/path/to/second
```

Compare the two build manifests before publication adds release lineage. The
comparison permits only build_id, built_at, and artifact/content SHA-256 to
change. It still checks every file against its own manifest and compares sizes.

## Workflows and releases

- **Build Android engine**: manually select a supported Flutter version, or
  `all` to build the support table serially; ABI defaults to arm64-v8a.
- **Check new Flutter stable**: daily, opens one tracking issue per unsupported
  stable version; it never starts an engine build.
- **Pipeline tests**: hosted Linux checks on pushes and pull requests. Engine
  builds run only on the repository's dedicated `engine-builder` runner.

Each successful engine release contains exactly the engine jar, unchanged
embedding jar, gen_snapshot-linux-x64, manifest.json, and build.log.zst. See the
[manifest contract](docs/manifest.md) for coordinates, hashes and verification.
The publisher verifies GitHub's uploaded SHA-256 digests before making its draft
release public. It never overwrites an existing tag; revisions use -rN and
supersedes. Promotion to the unsuffixed tag remains manual.

## Acceptance boundaries

WP-1 validates release integrity, engine/snapshot pairing, and repeatable manifest
metadata. Full M1 A10 additionally requires WP-2 doctor and the A1 application
update flow. Those integration results must remain pending until their work
packages exist. An unavailable device is recorded as skipped, never passed.
