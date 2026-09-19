# Engine patch provenance

`0001-dyn-module-factory-allocate-finalize.patch` changes only
`runtime/vm/bytecode_reader.cc` in the Dart dependency checkout. Apply it with
`git -C <engine>/engine/src/flutter/third_party/dart apply --check` and then
`git apply` in that same directory. The engine repository is the Flutter
monorepo; Dart is a separate DEPS checkout, not a tracked file of its parent.

The patch preserves the E8 prototype fix exactly. Before resolving a function,
finalize its class; require allocation finalization only for a resolved
generative constructor, not a factory. No object.cc diagnostic instrumentation
or dart2bytecode/kernel-front-end prototype changes are included.

Initial verified source identities (build validation pending):

- Flutter tag: 3.47.2 (`d3b14c876900e553bc736ca19295fc09e3853e8e`)
- Engine commit: `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`
- Dart dependency: `60a57cd42d64dc03e9f07aa60a2e250755c1ef28`

The experimental server was used only to recover the diff. This checked-in
patch is the authoritative build input. Applicability must be checked again
on each clean pinned checkout. Never apply with --3way or --force.

## Host-only patches

`engine_patches/<host>/*.patch` (today `windows-x64/`) are applied in addition
to the shared patches, but only by that host's `host_snapshot.py` build, and
are recorded as `host_patches` on that host's gen_snapshot record. They may only
fix code that the other hosts never compile; they never change engine
semantics, so they do not enter the shared `patches` identity that binds every
host to one release.

- `windows-x64/0001-interpreter-switch-dispatch-fatal.patch`: the bytecode
  interpreter's switch-dispatch fallback (used when computed goto is
  unavailable, i.e. clang-cl on Windows) still calls the removed `FATAL1`
  macro; upstream never builds `dart_dynamic_modules` on a Windows host.
  Replaces it with the variadic `FATAL`, two call sites, no behaviour change.
