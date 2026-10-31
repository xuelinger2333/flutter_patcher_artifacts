#!/usr/bin/env python3
"""iOS engine pipeline (macos-arm64 only).

Builds, from the same engine commit, pinned depot_tools and patches as the
Android release, the patched Flutter.framework for iOS devices and the
gen_snapshot that compiles iOS arm64 AOT, and packages them as one engine-ios
release (`engine-ios.manifest.json`, schema 1). Managed layout as in
host_snapshot.py (FLUTTER_PATCHER_ENGINE_HOME).

FLUTTER_PATCHER_XCODE names the Xcode.app to build with (default: the active
one). The engine's bundled lld must read that Xcode's SDK stubs: the 3.47
engine needs Xcode 26.x, as Xcode 27 SDKs add an arm64e.x1 target it rejects.

  build <version> --out DIR   fetch, patch, build, verify the snapshot, package
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

import hosts
from artifacts import InvalidArtifact, package_ios, require
from host_snapshot import REPO, Pipeline
from source_state import patches as patch_records

GN_ARGS = ['--ios', '--runtime-mode', 'release', '--no-prebuilt-dart-sdk', '--dart-dynamic-modules']
OUT = 'out/ios_release'
TARGETS = ['flutter/shell/platform/darwin/ios:flutter_framework',
           'flutter/lib/snapshot:create_macos_gen_snapshot_arm64_arm64']


class IosPipeline(Pipeline):
    def __init__(self, home):
        super().__init__(home)
        require(self.host == 'macos-arm64', 'the iOS engine builds only on macos-arm64')

    def build_engine(self, jobs):
        self.link_xcode(('MacOSX', 'iPhoneOS', 'iPhoneSimulator'))
        self.run(self.python(), self.src / 'flutter/tools/gn', *GN_ARGS, cwd=self.src)
        args = (self.src / OUT / 'args.gn').read_text()
        require(re.search(r'^dart_dynamic_modules = true$', args, re.M), 'dart_dynamic_modules is not true')
        self.run(self.engine / 'third_party/ninja/ninja', '-C', self.src / OUT, '-j', jobs, *TARGETS, cwd=self.src)
        framework = self.src / OUT / 'Flutter.framework'
        snapshot = self.src / OUT / 'artifacts_arm64/gen_snapshot_arm64'
        require((framework / 'Flutter').is_file() and snapshot.is_file(), 'iOS build artifacts missing')
        return framework, snapshot

    def verify_snapshot(self, sdk, gen_snapshot, work):
        """The pairing fixture compiled to iOS arm64 AOT assembly by the new gen_snapshot."""
        self.compile_kernel(sdk, work, 'ios')
        assembly = work / 'snapshot.S'
        self.run(gen_snapshot, '--deterministic', '--snapshot_kind=app-aot-assembly',
                 f'--assembly={assembly}', work / 'main.dill')
        # Newer Dart emits one kDartSnapshotText; older releases one symbol per snapshot part.
        text = assembly.read_text(errors='replace')
        require('kDartSnapshotText' in text or 'kDartIsolateSnapshotInstructions' in text,
                'gen_snapshot produced no iOS AOT snapshot')

    def build(self, version, out, jobs):
        out = Path(out).resolve()
        require(not out.exists() or not any(out.iterdir()), 'output directory is not empty')
        require(not self.git(REPO, 'status', '--porcelain'), 'builder repository is dirty')
        builder_commit = self.git(REPO, 'rev-parse', 'HEAD')
        self.say(f'iOS engine build {self.run_dir.name}: Flutter {version}, builder {builder_commit}')
        resolved = self.resolve(version)
        self.fetch(resolved['engine_commit'])
        applied = self.apply_patches()
        framework, snapshot = self.build_engine(jobs)
        require(self.git(self.src / 'flutter/third_party/dart', 'diff', '--full-index', '--binary', 'HEAD') == applied,
                'source patch changed during build')
        require(self.git(REPO, 'rev-parse', 'HEAD') == builder_commit and not self.git(REPO, 'status', '--porcelain'),
                'builder repository changed during build')
        sdk = Path(resolved['flutter_sdk'])
        flutter = hosts.flutter_launcher(self.host, sdk)
        self.run(flutter, '--suppress-analytics', 'precache', '--ios')
        self.verify_snapshot(sdk, snapshot, self.run_dir / 'verify')
        identity = {'flutter_version': version, 'engine_commit': resolved['engine_commit'],
                    'builder_repo_commit': builder_commit,
                    'depot_tools_rev': (REPO / 'DEPOT_TOOLS_REV').read_text().strip(),
                    'patches': patch_records(REPO), 'toolchain': self.toolchain}
        package_ios(framework, sdk / 'bin/cache/artifacts/engine/ios-release/Flutter.xcframework', snapshot,
                    identity, {'snapshot': 'passed', 'device': 'skipped', 'device_reason': 'no_ios_device'}, out)
        self.say(f'IOS_ENGINE_READY: {out}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--home', default=os.environ.get('FLUTTER_PATCHER_ENGINE_HOME') or str(Path.home() / '.flutter_patcher/engine-builder'))
    commands = parser.add_subparsers(dest='command', required=True)
    build = commands.add_parser('build')
    build.add_argument('version')
    build.add_argument('--out', required=True)
    build.add_argument('--jobs', type=int, default=int(os.environ.get('FLUTTER_PATCHER_BUILD_JOBS', '0')) or max(2, (os.cpu_count() or 4) // 2))
    args = parser.parse_args()
    pipeline = None
    try:
        pipeline = IosPipeline(args.home)
        pipeline.build(args.version, args.out, args.jobs)
    except (InvalidArtifact, OSError, ValueError, KeyError, subprocess.CalledProcessError, hosts.HostError) as error:
        print(f'IOS_ENGINE_FAILED: {error}', file=sys.stderr)
        return 1
    finally:
        if pipeline is not None:
            pipeline.log.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())