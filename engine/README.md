# Engine build sources

Maintainer build environment: Linux x86_64, Android arm64-v8a release target;
Git, Python 3, pinned depot_tools, GN/Ninja, flock, zstd, GNU time, and the Flutter
engine's system prerequisites. `DEPOT_TOOLS_REV` is fixed at repository root.
Use a dedicated managed directory, never a user's Flutter SDK or application.

The build workflow invokes `engine/scripts/build.sh`, which resolves the engine,
fetches dependencies, verifies and applies patches, builds fixed targets, packages
the artifacts, then verifies the engine/gen_snapshot pair. Both are bound by one
`build_id` in `engine.manifest.json`. The embedding jar is copied unchanged.

| New-layout measurement | Value |
|---|---|
| Build host CPU / memory / filesystem | Linux x64; 8 CPUs; 16,773,283,840 B RAM; 539,792,977,920 B filesystem |
| Initial fetch/sync and build duration | 216.62 s fetch/sync; 1,026.50 s build stage including GN and checks; Ninja itself 1,024.902 s with -j8 |
| Runner cgroup memory.peak | 12,234,321,920 B, including charged file cache, service lifetime through first build verification; not aggregate peak RSS |
| Checkout / output apparent size after build | 26,843,462,179 B / 1,367,516,597 B (`du -sb`) |
| Engine jar / gen_snapshot / embedding jar size | 11,908,360 B / 6,295,056 B / 1,584,072 B |
| Sync-only disk / aggregate peak RSS | TBD; not separately measured |

Two new-layout builds passed on 2026-09-08 at source commit
`8518c2dfd962139c2283c9244e4ae09cf4143d22`. Both outputs were downloaded and verified
against their manifests. Comparable manifest fields and all three artifact hashes
matched. The second build reused the cache (17.65 s sync, 233.04 s build stage).
Full hashes, measurement scope, repeatability results and
CI links are in the [acceptance record](../docs/WP1_WP1b_构建验收_2026-09-08.md).
Historical measured evidence remains under `engine/measurements/`.
Device verification and doctor/A1 remain pending. Logs remain local build evidence;
they are not uploaded as Release assets by the new publisher.

No user-facing source-build fallback is provided. Runner provisioning is a
maintainer operation performed by the user after review.
