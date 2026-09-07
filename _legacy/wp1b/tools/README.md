# Versioned tool releases (WP-1b)

The tool pipeline runs on GitHub-hosted Ubuntu with stock Flutter, separately
from `flutter_patcher_engine`. `supported_versions.txt` is maintained in both
repositories; the workflow fails if the tables differ. `versions.json` pins each
Flutter version's engine and Dart source commit. No dependency is added to the
plugin package.

`tools-release.yml` builds and tests on relevant pushes/PRs. Manual dispatch can
select one supported version or `all`; only a manual dispatch with `publish`
enabled creates a release. The five attachments are the kernel-tools dill,
patched dart2bytecode dill, protocol YAML, platform-private YAML, and manifest.
Publication starts as a draft, verifies each uploaded SHA-256 digest, then makes
it public. Existing tags are preserved; another release gets `-r2`, `-r3`, etc.

## Inputs and replacement machines

Install Git, Python 3, and the selected stock Flutter under
`~/.flutter_patcher/`. The hosted workflow uses the commit-pinned
[subosito Flutter action](https://github.com/subosito/flutter-action).
No experimental server checkout or engine build is needed. From a clean commit:

```bash
python3 tools/release/build_tools.py 3.47.2 \
  --flutter "$HOME/.flutter_patcher/flutter-3.47.2" \
  --work "$HOME/.flutter_patcher/tools-runs/first" \
  --out "$HOME/.flutter_patcher/tools-releases/3.47.2"
```

The work and output directories must be new. The script makes private source,
SDK-source, and pub-cache copies under the work directory. It clones the Dart
version tag, checks its exact commit, and checks/applies the reviewed patch.
`pubspec_overrides.yaml` selects that checkout's kernel/front_end/vm packages;
SDK workspace participation is disabled through the
[documented pub override](https://dart.dev/tools/pub/workspaces#temporarily-resolving-a-package-outside-its-workspace).
Hosted dependency versions and hashes are pinned in `locks/<flutter>.lock` and
enforced by `dart pub get --enforce-lockfile`. User SDKs and applications are
never modified by these scripts.

## Validation and scope

The pipeline runs structural detector tests, compiles the nine F6 Flutter
fixtures, then runs the compiled kernel-tools snapshot against fixed verdicts
and injection/bypass counts. It compiles all four artifacts twice with the same
source/dependency paths and requires identical manifests and SHA-256 hashes
(A11). This test does not assert reproducibility across different absolute
workspace paths. Both dill files run independently of package configuration;
dart2bytecode additionally compiles a no-main module with `--aot-only` and `--tfa`.

`kernel_tools` currently exposes the migrated `detect-shape` and
`transform-overlay` commands. The other analysis commands from SPEC_M1 §4.5
belong to subsequent work packages; they are not advertised as implemented.
The protocol generator here resolves only the fixed framework protocol tier
against the selected Flutter kernel. App surface extraction, union/fixpoint
logic, CLI/doctor, and runtime changes are outside WP-1b.

The protocol definitions derive from the E1 prototype, excluding its demo-app
entries and the separate dart:core/dart:ui tiers. Missing framework libraries or
classes fail generation. The platform-private generator retains the F1 logic.
F4's tool patch enables TFA/AOT flags, preserves host call signatures, handles
modules with no main, and passes through `FileUriExpression`. It changes no
engine/runtime files. Raw prototype migration and subsequent changes are kept
in separate commits.

## Manifest and evidence

`manifest.json` follows SPEC_M1 §4.6. Each of its four `files` has the exact
versioned name, role, size and SHA-256. It also records the Flutter/Dart versions,
engine commit, this builder's commit, Dart source commit, and patch hashes.
`tools_artifacts.py validate <release>` rejects missing/duplicate roles, corrupt
files, unsupported schema, and wrong filenames. `compare <first> <second>`
requires byte-identical artifacts. The build log, two manifests, fixture
results and measured duration are retained as Actions evidence, outside the
five release attachments. Full doctor acceptance awaits WP-2.

## Accepted release — 2026-09-07

[tools-3.47.2](https://github.com/xuelinger2333/flutter_patcher/releases/tag/tools-3.47.2)
was built and published by
[hosted run 34100568067](https://github.com/xuelinger2333/flutter_patcher/actions/runs/34100568067),
from source commit `dc326fad2bccaccc2d608c63f0d3a570c64ec367`.
The preceding [push CI](https://github.com/xuelinger2333/flutter_patcher/actions/runs/34100551767)
also passed. Both runs passed A11, all nine snapshot fixtures, structural tests,
and real no-main module compilation with both patched compiler modes. There are
21 Python contract tests and 9 detector structural checks. Snapshot transformation
also preserves both branches in shape 4 and the bypass classification in shape 7.

| Measured item | Value |
| --- | --- |
| Hosted single-version build/publish job | 3 min 11 s (Actions timestamps) |
| Double-build and verification step | 2 min 02 s (included above; not a single compiler invocation) |
| kernel-tools dill | 13,617,672 bytes |
| dart2bytecode dill | 36,986,640 bytes |
| protocol YAML | 5,657 bytes; 174 checked Flutter protocol class entries |
| platform-private YAML | 1,698,340 bytes |

All five published assets were independently downloaded and verified against
GitHub's SHA-256 digests and the tools manifest. The engine commit matches the
public `engine-3.47.2` manifest. Both downloaded snapshots ran `--help` in an
isolated directory with stock Dart 3.13.2, without a package configuration.
The doctor subcommand itself remains WP-2 work.

Evidence: [measurements/WP1b-2026-09-07](measurements/WP1b-2026-09-07/).
