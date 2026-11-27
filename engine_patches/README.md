# Engine patch provenance

`0001-dyn-module-factory-allocate-finalize.patch` changes only
`runtime/vm/bytecode_reader.cc` in the Dart dependency checkout. Apply it with
`git -C <engine>/engine/src/flutter/third_party/dart apply --check` and then
`git apply` in that same directory. The engine repository is the Flutter
monorepo; Dart is a separate DEPS checkout, not a tracked file of its parent.

Before resolving a function, the patch finalizes its class, and it requires
allocation finalization only for a resolved generative constructor, not a
factory.

Verified source identities:

- Flutter tag: 3.47.2 (`d3b14c876900e553bc736ca19295fc09e3853e8e`)
- Engine commit: `a804b261645ef8c13eb3d5c44a5c2fb0340c5539`
- Dart dependency: `60a57cd42d64dc03e9f07aa60a2e250755c1ef28`

This checked-in patch is the authoritative build input. Applicability must be checked again
on each clean pinned checkout. Never apply with --3way or --force.

`0002-aot-guarded-single-target-calls.patch` changes only the AOT compiler
under `runtime/vm/compiler/` in the same Dart checkout, so only gen_snapshot;
libflutter.so is the same with and without it. It adds two gen_snapshot
flags, both off unless passed:

- `--guard_single_target_calls`: a call of a member that a dynamic module may
  override, and that has one implementation among the precompiled classes,
  is compiled as a class id check and a direct call of that implementation,
  with the dispatch the compiler emitted before on the other branch. Without
  it every such call goes through the slower dispatch, which is what a host
  that keeps whole packages overridable would pay on each of their calls.
- `--lazy_dyn_module_tearoffs`: a dynamic module pragma no longer forces a
  precompiled tear-off of every method it makes callable; a tear-off is
  compiled where the program takes one, as without the pragma.

The CLI passes both when the engine release lists `guarded_calls`.

Verified source identity: Flutter 3.50.0, Dart `fa8c1270c37` (3.14.0).

`0003-aot-allocation-sinking-non-array-store.patch` changes only
`runtime/vm/compiler/backend/redundancy_elimination.cc`, so only gen_snapshot.
Allocation sinking took every allocation an indexed store writes to for an
array allocation and read its length; for an object indexed like an array,
as a typed data view is (`Uint8List.view(b)..[0] = x`), it read through a
null pointer and gen_snapshot crashed. Such an allocation is now left as it
is. A host that keeps whole packages compiles code a smaller host never
reaches, which is how the crash showed (package `image`, the WebP reader).
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

## Flutter monorepo patches

`flutter/*.patch` apply with `git -C <engine> apply` in the Flutter monorepo
itself (paths start with `engine/src/flutter/`), after the Dart patches. They
are shared patches: listed in the same `patches` identity, and every pipeline
records and reverts them like the Dart ones (`cache/applied-flutter.patch`).
File names must differ from the Dart patches'.

- `flutter/0001-patcher-asset-channel.patch` changes only
  `shell/common/engine.cc`. The engine answers the `flutter_patcher/assets`
  platform message: a payload of authenticated patch assets (u32 count, then
  per asset u32 key size, key, u32 byte size, bytes; little-endian) becomes an
  in-memory resolver in front of the application bundle, and the fonts are
  registered again when it carries a `FontManifest.json`. It replies `1`, or
  empty for a malformed payload; an engine without the patch forwards the
  message to the embedder, which also replies empty. The CLI accepts asset
  changes only for hosts whose engine release lists this patch.