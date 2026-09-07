# Engine manifest contract (schema 1)

The base fields follow SPEC_M1 section 4.6. This document specifies the WP-1
producer's validation and the additive metadata needed by later consumers.

## Identity

Required top-level fields: schema (1), flutter_version, engine_commit,
engine_stamp, build_id (UUID v4), built_at (UTC ISO 8601), builder_repo_commit,
depot_tools_rev, patches, files.

build_id identifies one build invocation and applies to all files in the
manifest. It is not the ELF linker build ID and is not independently injected
into the binaries. A valid manifest plus matching SHA-256 hashes binds the
downloaded files to this invocation. Actual runtime compatibility is checked
separately by compiling and loading a minimal AOT snapshot.

Engine and builder commits and depot_tools_rev are full 40-digit lowercase
hex Git IDs. patches lists every applied patch, sorted by filename, with its
SHA-256. A dirty builder checkout cannot produce a release.

## Required artifacts

| role | name | Attributes |
| --- | --- | --- |
| engine | libflutter-arm64_v8a-release.jar | abi: arm64-v8a; Maven coordinate io.flutter:arm64_v8a_release:1.0.0-<engine_stamp> |
| embedding | flutter_embedding_release.jar | Maven coordinate io.flutter:flutter_embedding_release:1.0.0-<engine_stamp> |
| gen_snapshot | gen_snapshot-linux-x64 | host_os: linux; host_arch: x64 |

Each file has a SHA-256 and a positive integer byte size. Each role appears
exactly once in M1. File names are basenames, never absolute paths or paths
with traversal. The engine jar contains lib/arm64-v8a/libflutter.so.

The engine file entry additionally has `contents`, a list with the path,
SHA-256, and byte size of the libflutter.so entry. Later APK verification can
compare this hash directly; comparing the APK's SO hash to the whole jar hash
would be incorrect. These fields are additive to SPEC_M1's example.

The embedding jar is copied byte-for-byte from the same build. Release logs
are attached as build.log.zst; they are diagnostic output, not runtime inputs
in files. No dill, tool snapshot, or interface YAML is published here.

## Verification

`verify` has stable fields:

```json
{
  "snapshot": "passed",
  "device": "skipped",
  "device_reason": "no_android_device"
}
```

Before verification, snapshot/device may be `pending`; such a manifest is not
publishable. Snapshot compilation must pass even without a device. A device
failure must fail verification; it cannot be converted to skipped. A passed
device check sets device_reason to null. Timings, device IDs, and temporary
paths are kept in logs, not this stable result.

## Repeated builds and releases

For the same inputs and verification environment, compare the complete JSON
after excluding top-level build_id/built_at and file/content SHA-256 values.
Do not require native binaries to be byte-identical; do check each build's
files against its own manifest. Report any other metadata or size difference.

The normal tag is engine-<flutter_version>. An existing tag must never have
assets replaced. A revision uses the next free -rN suffix and a supersedes
field pointing to the previous tag. Promotion to the unsuffixed tag is a
separate manual operation; the publisher does not move tags or overwrite
release assets.
