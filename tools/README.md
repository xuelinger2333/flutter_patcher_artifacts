# CI-built Flutter tools

CI compiles `tools/kernel_tools/bin/main.dart` with the pinned stock Dart SDK and
reviewed Dart source patches into one `flutter_patcher_tools-<version>.dill`.
Only that file is listed in `tools.manifest.json`. Users never compile this dill.

Implemented subcommands:

- `detect-shape` and `transform-overlay`: migrated analysis behavior and fixtures.
- `bytecode`: forwards arguments to the patched dart2bytecode entry point.
- `gen-protocol-interface --dill <linked-flutter.dill> --out <file>`.
- `gen-platform-privates --platform <platform.dill> --out <file>`.

The protocol definition is embedded in `generators/protocol_set/definitions.dart`.
After editing its YAML source, maintainers run `embed_definitions.py`; CI checks
that the embedded copy agrees. Traversal logic is unchanged. Both generated YAML
files are user-side cache entries, not Release assets. CLI orchestration of SDK
inputs, cache invalidation and doctor belongs to WP-2 and is not implemented here.

The other four specified analysis commands remain unimplemented, as approved for
M1.5. The combined entry point passed hosted CI on 2026-09-08: two builds with
identical manifests and snapshot hashes, nine fixtures, both generators,
transform-overlay, and bytecode compilation with --aot-only and --tfa.
The build verification step took 111.11 seconds. See the
[acceptance record](../docs/WP1_WP1b_构建验收_2026-09-08.md).
This publish=false run retained logs but no uploaded dill; Release download and
doctor integration remain unverified.

`build-tools.yml` uses hosted CI independently of the engine workflow. All upload
steps are gated by `inputs.publish == true`, default false. The publisher requires
an existing `flutter-<version>` Release and fails on missing releases or duplicate
asset names. It does not alter the release's draft state.
