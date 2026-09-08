# WP-3 tools source implementation

2026-09-08, local `codex/wp3`, pending review. No push, tag, release modification,
engine patch or engine workflow change was performed for WP-3.

New commands compiled into the existing single CI dill:

- `extract-surface`: owned-library references, constants, enum retention, inheritance,
  and a distinct trim interface retaining imported barrels.
- `merge-interface`: canonical union with protocol/default sets and whole-mode
  platform declarations. It never emits duplicate YAML section keys.
- `resolve-interface-hints`: actual imported/exported declarations, show/hide filters,
  implicit dart:core only, unresolved and ambiguous hints fail.
- `trim-interface`: the pinned SDK frontend trimmer for lean validation.

The extractor originates from the untracked code-repository prototype
`temp/extract_referenced_surface.dart` (SHA-256
`9c601dfc904ea3644aae0072d8bbf078f44a6f8b8bf01f90c8e7beffd0acf55a`).
The hint resolver replaces the prototype `temp/e2_resolve_hints.dart` (SHA-256
`785d6de71a38c4f9f5f41590216b4ccb80072b7e6bcb634103d5ff532edfe6b3`).
Those files were untracked, so no Git source commit is invented. Both originals
remain untouched in the code repository's ignored temp directory.

Measured source validation on Linux with Flutter 3.47.2 / Dart 3.13.2:

- New tool sources: analyzer passed; 9 interface structural cases passed.
- Existing detect_shape structural cases: 9 passed.
- Python pipeline contracts: 23 passed on Windows.
- Actual source-entry integration: lean converged in 2 rounds (133,977-byte
  bytecode); whole passed in 1 round (8,832,525-byte bytecode).
- Repeated merges produced byte-identical build/trim interfaces.
- Code-repository CLI source integration also converged in 2 lean rounds.

Raw compact evidence and the detailed scope are in the code repository's
`flutter_patcher_cli/docs/WP3-acceptance.md` and `docs/wp3-evidence/` beneath that
CLI package. Full server evidence is under `/root/.flutter_patcher/wp3-development/`.

`build_tools.py` now executes the structural cases and `interface_smoke.py` on its
CI-built snapshot; existing double builds and A11 remain. No new tool dill was
built locally, and the updated CI has not run yet. CI dill size/time/A11 are TBD.
After source review, push the test branch and run with publish=false. Existing
release assets cannot be replaced by the publisher without separate review.
No application/device/A1 acceptance is claimed by these source checks.
