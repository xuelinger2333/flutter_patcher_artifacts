# WP-1 acceptance record — 2026-09-07

The official source was created locally in `D:\DevProjects\flutter_patcher_engine`
and then synchronized to GitHub and a dedicated Linux builder directory.
Existing server experiments were used only to recover the reviewed E8 patch.
The supported release set contains Flutter 3.47.2, Android arm64-v8a, Linux x64.

## Published release and repeatability

- [Build and publish workflow](https://github.com/xuelinger2333/flutter_patcher_engine/actions/runs/34092945313): passed.
- [engine-3.47.2 release](https://github.com/xuelinger2333/flutter_patcher_engine/releases/tag/engine-3.47.2): exactly five attachments.
- Release builder commit: `db12b3da388256906f8866b74a2d9dedfb9917c7`.
- First build ID: `469e10a2-6aa3-4099-8142-f27e4b3bff0e`.
- Release build ID: `3e272ad1-0765-41cd-98da-059525837db5`.
- All five attachments were independently downloaded and checked against the
  GitHub upload SHA-256 digests. The manifest validator also checked the three
  runtime artifacts and the engine jar's inner native library.
- `python3 scripts/artifacts.py compare <first> <release>` passed. All three
  main artifact hashes were identical; build UUID/time changes were allowed.
- Both runs compiled the minimal kernel to an arm64 AOT ELF with the custom
  gen_snapshot. Device checks recorded `skipped/no_android_device`.

The two manifests, compressed logs, and machine-readable comparison result are
in [measurements/repeatability-2026-09-07](../measurements/repeatability-2026-09-07/).
The build log for a warm rebuild is short because Ninja reused existing output;
the full clean compilation log is retained separately with the T-1 measurements.

## Pipeline checks

- `python3 -m unittest discover -s scripts/test -v`: 41 tests passed locally on
  Windows and in [hosted Linux CI](https://github.com/xuelinger2333/flutter_patcher_engine/actions/runs/34093454708).
- `bash -n scripts/*.sh` (each script separately) and actionlint 1.7.12 passed.
- [Stable-version checker](https://github.com/xuelinger2333/flutter_patcher_engine/actions/runs/34092522383): passed its manual workflow run;
  the workflow is also scheduled daily and only opens a tracking issue.
- The dedicated `engine-builder` runner was registered and its service enabled.
- Subsequent helper commit `baf219f10ed432ea8ebeeb48ca7ea74b7edc1fe8` moved
  verification scratch files into the managed cache and allowed isolated retries.
  The updated helper passed an actual Linux kernel/AOT smoke run. This did not
  change the native build recipe; the release retains its original builder commit.

## Cross-commit incremental measurement

Using the same persistent source/output cache and helper commit `baf219f`, first
prepare Flutter 3.47.1's engine `5d531788691ec3404cac0cee66ead4007b177363`,
then switch back to 3.47.2's `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`.
Both commits accepted the same E8 patch with `git apply --check`.

| Stage | Wall time | Included in reported incremental time? |
| --- | --- | --- |
| Prepare older source and dependencies | 3 min 36.78 s | No |
| Build older baseline | 6 min 14.09 s | No |
| Switch source and dependencies to current engine | 28.45 s | Reported separately |
| Build current engine in the existing output directory | 6 min 15.91 s | Yes; GN, assertions, and Ninja `-j8` |

GNU time measured each script invocation separately, with all four exit statuses
zero. The current build completed 492 Ninja tasks. The final engine commit and
patch hashes matched the official release inputs; packaging and minimal AOT
compilation passed. The complete log ends with `INCREMENTAL_BENCHMARK_PASSED`.
No benchmark release was published, and 3.47.1 was not added to the support table.
Raw time files, source identities, final manifest, exact manual script, and full
compressed log are in
[measurements/incremental-2026-09-07](../measurements/incremental-2026-09-07/).

## Scope of the result

WP-1's source pipeline, first release, measurements, integrity checks, and
repeat-build comparison are delivered. Full M1 A10 remains pending: its WP-2
doctor download/check and A1 application update flow require other work packages.
No physical or emulated device was available, so runtime pairing was not tested
and must not be reported as passed. The device path rejects attached but offline,
unauthorized, incompatible, or failing devices instead of silently skipping them.

WP-1b, CLI/doctor, plugin/runtime changes, and the other work packages were not
implemented in this work.
