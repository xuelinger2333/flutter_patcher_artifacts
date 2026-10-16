# CI-built Flutter tools

CI compiles `tools/kernel_tools/bin/main.dart` with the pinned stock Dart SDK and
reviewed Dart source patches into one `flutter_patcher_tools-<version>.dill`.
Only that file is listed in `tools.manifest.json`. Users never compile this dill.

Implemented subcommands:

- `detect-shape` and `transform-overlay`: asset-overlay injection-point detection and the matching kernel transform.
- `bytecode`: forwards arguments to the patched dart2bytecode entry point.
- `gen-protocol-interface --dill <linked-flutter.dill> --out <file>`.
- `gen-platform-privates --platform <platform.dill> --out <file>`.
- `gen-framework-partition --platform <platform.dill> --dill <linked-flutter.dill> --out <partition.json>` computes the deterministic host/carry split and the framework-reuse surface.
- `extract-surface --dill --own --out-iface --out-trim-iface`: framework surface referenced by the app's own packages.
- `merge-interface`: deterministic four-part union and separate trim interface; `--framework-reuse` adds the validated reuse surface.
- `resolve-interface-hints`: module-import-scoped, ambiguity-rejecting hint resolution.
- `trim-interface`: pinned SDK trimmer for lean validation, bundled into the same dill.
- `compile-baseline`, `inspect-build`, `compile-patch`, `check-allocations`,
  `check-inherited` and `verify-structure`: see `--help`.

The protocol definition is embedded in `generators/protocol_set/definitions.dart`.
After editing its YAML source, maintainers run `embed_definitions.py`; CI checks
that the embedded copy agrees. Both generated YAML files are user-side cache
entries, not Release assets. CLI orchestration of SDK inputs, cache invalidation
and doctor belongs to the code repository and is not implemented here.

`build_tools.py` compiles the dill twice and fails unless both builds produce
identical manifests and artifact hashes.

`package:kernel` analysis, frontend trimming and version-specific default sets
live here. The code repository CLI only orchestrates these subcommands. Interface YAML
is project output, never a release asset. `build_tools.py` runs structural interface
tests and `interface_smoke.py` against the CI-built snapshot: actual extraction,
merge determinism, trimming, compiler-hint convergence and lean/whole bytecode validation.

`build-tools.yml` uses hosted CI independently of the engine workflow. All upload
steps are gated by `inputs.publish == true`, default false. The publisher requires
an existing `flutter-<version>` Release and fails on missing releases or duplicate
asset names. It does not alter the release's draft state.
