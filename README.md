# flutter_patcher_artifacts

Version-bound build sources for flutter_patcher. This local M1.5 restructuring
branch is awaiting review. No remote repository, tag or release was created.

`supported_versions.txt` is the single support table. Users supply their Flutter
version through the CLI's `flutter --version --machine` detection. Unsupported
versions fail; users are not asked to build an engine or tool snapshot.

The engine and tools workflows run independently. Engine builds use a dedicated
Linux x64 self-hosted runner; tool snapshots are compiled by hosted CI. They upload
to an existing, user-created `flutter-<version>` Release only when the workflow's
`publish` input is true (default false). The uploaders never create tags, create
releases, replace existing assets, or publish drafts.

Release assets:

- `libflutter-arm64_v8a-release.jar`
- `gen_snapshot-linux-x64`
- `flutter_embedding_release.jar` (pass-through pending WP-5 verification)
- `engine.manifest.json`
- `flutter_patcher_tools-<version>.dill`
- `tools.manifest.json`

YAML is generated on the user's machine by subcommands of the CI-built dill and
cached by the future CLI in `~/.flutter_patcher/`. It is not a release asset.
See [engine requirements](engine/README.md), [tool contract](tools/README.md), and
[migration sources](docs/migration-sources.json). `_legacy/` and
`engine/measurements/` preserve historical evidence; they describe old releases.
