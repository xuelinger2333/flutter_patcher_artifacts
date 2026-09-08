# CI-built Flutter tools

CI compiles `tools/kernel_tools/bin/main.dart` with the pinned stock Dart SDK and
reviewed Dart source patches into one `flutter_patcher_tools-<version>.dill`.
Only that file is listed in `tools.manifest.json`. Users never compile this dill.

Implemented subcommands:

- `detect-shape` and `transform-overlay`: migrated analysis behavior and fixtures.
- `bytecode`: forwards arguments to the patched dart2bytecode entry point.
- `gen-protocol-interface --dill <linked-flutter.dill> --out <file>`.
- `gen-platform-privates --platform <platform.dill> --out <file>`.
- `extract-surface --dill --own --out-iface --out-trim-iface`: WP-3 referenced surface.
- `merge-interface`: deterministic four-part union and separate trim interface.
- `resolve-interface-hints`: module-import-scoped, ambiguity-rejecting hint resolution.
- `trim-interface`: pinned SDK trimmer for lean validation, bundled into the same dill.

The protocol definition is embedded in `generators/protocol_set/definitions.dart`.
After editing its YAML source, maintainers run `embed_definitions.py`; CI checks
that the embedded copy agrees. Traversal logic is unchanged. Both generated YAML
files are user-side cache entries, not Release assets. CLI orchestration of SDK
inputs, cache invalidation and doctor belongs to WP-2 and is not implemented here.

The remaining check-allocations, check-inherited and verify-structure commands
belong to later work packages. The pre-WP-3 combined entry point passed hosted CI on 2026-09-08: two builds with
identical manifests and snapshot hashes, nine fixtures, both generators,
transform-overlay, and bytecode compilation with --aot-only and --tfa.
The build verification step took 111.11 seconds. See the
[acceptance record](../docs/WP1_WP1b_构建验收_2026-09-08.md).
This publish=false run retained logs but no uploaded dill; Release download and
doctor integration were unverified in that historical run. The later WP-2 release
and doctor acceptance are recorded in the code repository. WP-3 source validation
does not by itself establish acceptance of a newly built CI dill.

WP-3 keeps `package:kernel`, frontend trimming and version-specific default sets
here. The code repository CLI only orchestrates these subcommands. Interface YAML
is project output, never a release asset. `build_tools.py` runs structural interface
tests and `interface_smoke.py` against the CI-built snapshot: actual extraction,
merge determinism, trimming, compiler-hint convergence and lean/whole bytecode validation.

`build-tools.yml` uses hosted CI independently of the engine workflow. All upload
steps are gated by `inputs.publish == true`, default false. The publisher requires
an existing `flutter-<version>` Release and fails on missing releases or duplicate
asset names. It does not alter the release's draft state.
