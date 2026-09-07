# WP-1b evidence

All successful pipeline records here refer to builder commit
`dc326fad2bccaccc2d608c63f0d3a570c64ec367`, Flutter 3.47.2, and Dart 3.13.2.

- `prototype-check.log.gz`: original migration check, before CLI refactoring;
  nine shape verdicts, eight transform/readback checks and platform generation.
- `ci-first-manifest.json`, `ci-second-manifest.json`: two identical manifests
  from hosted run [34100551767](https://github.com/xuelinger2333/flutter_patcher/actions/runs/34100551767).
  The downloaded CI archive's hash was checked, and each archived runtime asset
  was independently checked against the first manifest.
- `ci-*-smoke.json`, `ci-verification.json`, `ci-build.log.gz`: fixed-answer
  snapshot checks, A11 result, compiler tests, and the complete CI build log.
- `release-manifest.json`: manifest independently downloaded from `tools-3.47.2`.
- `publication.json`, `publish-job.log.gz`: asset digests, measured timings,
  job timestamps, and the full successful publication-job log from
  [34100568067](https://github.com/xuelinger2333/flutter_patcher/actions/runs/34100568067).
- `download-verification.json`: fresh public-Release downloads on Linux;
  all five GitHub digests checked, engine manifest matched, and both dill help
  commands executed without a package configuration. A separate Windows
  download also passed all five digests and `tools_artifacts.py validate`.

The two CI manifests compare builds within one source/dependency workspace.
The publication run has different absolute source paths; no cross-workspace
binary equality is claimed. Its own two-build comparison also passed, as
recorded in the publication job log. CLI/doctor integration remains WP-2 work.
