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
| Build host CPU / memory / disk | TBD |
| Initial sync and build duration | TBD |
| Peak memory / checkout and output size | TBD |
| Rebuilt artifact sizes and hashes | TBD |

Historical measured evidence is retained under `engine/measurements/`; it does
not certify the new paths or packaging. T-1 did have a real successful build.
Device verification and doctor/A1 remain pending. Logs remain local build evidence;
they are not uploaded as Release assets by the new publisher.

No user-facing source-build fallback is provided. Runner provisioning is a
maintainer operation performed by the user after review.
