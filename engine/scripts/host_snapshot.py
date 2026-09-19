#!/usr/bin/env python3
"""Secondary-host gen_snapshot pipeline (WP-2.6 phase C).

Runs on windows-x64 (verified on the maintainer's machine) and macos-arm64
(implemented, not yet verified). linux-x64 stays the primary host and keeps
build.sh. The managed layout under WP1_HOME matches common.sh:
cache/depot_tools, cache/engine, cache/flutter-<version>, runs/<id>.

  fetch  <version>            checkout depot_tools and the engine at the version's commit
  build  <version> --out DIR  fetch, patch, build gen_snapshot, verify it, write a bundle
  attach <release> <bundle>   merge the bundle into a release and pair it on a device
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

import hosts
from artifacts import InvalidArtifact, attach, elf_machine, read_json, require, sha256, validate_bundle, write_json
from source_state import check_clean, patches as patch_records

REPO = Path(__file__).resolve().parents[2]
DEPOT_REMOTE = 'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
FLUTTER_REMOTE = 'https://github.com/flutter/flutter.git'
# Fixed recipe shared with build_android.sh; no overrides.
GN_ARGS = ['--android', '--android-cpu', 'arm64', '--runtime-mode', 'release',
           '--no-prebuilt-dart-sdk', '--dart-dynamic-modules']
OUT = 'out/android_release_arm64'
VS_VERSIONS = (('18', '2026'), ('2022', '2022'))
VS_PRODUCTS = ('Enterprise', 'Professional', 'Community', 'Preview', 'Insiders', 'BuildTools')


def write_patch(path, diff):
    """Byte-exact so `git apply --reverse` accepts it on Windows (no CRLF translation)."""
    Path(path).write_bytes((diff + '\n').encode('utf-8'))


def read_patch(path):
    return Path(path).read_bytes().decode('utf-8').rstrip('\n')


class Pipeline:
    def __init__(self, home):
        self.host = hosts.current()
        require(self.host in hosts.SECONDARY, f'{self.host} is not a secondary host; linux-x64 uses build.sh')
        self.windows = self.host.startswith('windows-')
        self.home = Path(home).resolve()
        require(self.home.is_absolute(), 'WP1_HOME must be an absolute managed directory')
        if self.windows:
            require(len(str(self.home)) <= 24, 'WP1_HOME must be short on Windows (MAX_PATH), e.g. D:\\fpe')
        self.cache = self.home / 'cache'
        self.depot = self.cache / 'depot_tools'
        self.engine = self.cache / 'engine'
        self.src = self.engine / 'engine/src'
        self.run_dir = self.home / 'runs' / str(uuid.uuid4())
        self.run_dir.mkdir(parents=True)
        self.log = (self.run_dir / 'build.log').open('a', encoding='utf-8')
        self.toolchain = {}
        self.env = self.environment()

    # -- process helpers -------------------------------------------------
    def say(self, message):
        print(message, flush=True)
        self.log.write(message + '\n')
        self.log.flush()

    def run(self, *args, cwd=None, capture=False, env=None):
        command = [str(arg) for arg in args]
        self.say('+ ' + ' '.join(command))
        process = subprocess.Popen(command, cwd=cwd, env=env or self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
        output = []
        for line in process.stdout:
            self.log.write(line)
            if capture:
                output.append(line)
            else:
                sys.stdout.write(line)
        self.log.flush()
        sys.stdout.flush()
        require(process.wait() == 0, f'command failed ({process.returncode}): {command[0]}')
        return ''.join(output).strip()

    def git(self, path, *args):
        return self.run('git', '-C', path, *args, capture=True)

    def environment(self):
        env = dict(os.environ)
        env['DEPOT_TOOLS_UPDATE'] = '0'
        env.pop('FLUTTER_STORAGE_BASE_URL', None)
        # Applied to every git the pipeline or gclient spawns, without touching user config.
        settings = [('core.longpaths', 'true'), ('core.autocrlf', 'false'), ('core.filemode', 'false')]
        env['GIT_CONFIG_COUNT'] = str(len(settings))
        for index, (key, value) in enumerate(settings):
            env[f'GIT_CONFIG_KEY_{index}'] = key
            env[f'GIT_CONFIG_VALUE_{index}'] = value
        env['PATH'] = str(self.depot) + os.pathsep + env['PATH']
        if self.windows:
            env['DEPOT_TOOLS_WIN_TOOLCHAIN'] = '0'
            studio, year = self.visual_studio(env)
            env['GYP_MSVS_VERSION'] = year
            env['GYP_MSVS_OVERRIDE_PATH'] = str(studio)
            env[f'vs{year}_install'] = str(studio)
        return env

    def visual_studio(self, env):
        """Locates a VS 2026/2022 install with the C++ toolset; records it for the manifest."""
        candidates = []
        if env.get('GYP_MSVS_OVERRIDE_PATH'):
            candidates.append((Path(env['GYP_MSVS_OVERRIDE_PATH']), env.get('GYP_MSVS_VERSION')))
        for folder, year in VS_VERSIONS:
            for root in (env.get('PROGRAMFILES'), env.get('PROGRAMFILES(X86)')):
                for product in VS_PRODUCTS:
                    if root:
                        candidates.append((Path(root) / 'Microsoft Visual Studio' / folder / product, year))
        for studio, year in candidates:
            toolsets = sorted((studio / 'VC/Tools/MSVC').glob('*')) if studio.is_dir() else []
            if (studio / 'VC/Auxiliary/Build/vcvarsall.bat').is_file() and toolsets and year:
                kits = Path(env.get('PROGRAMFILES(X86)', 'C:/Program Files (x86)')) / 'Windows Kits/10/Include'
                sdks = sorted(p.name for p in kits.glob('10.*')) if kits.is_dir() else []
                require(bool(sdks), 'Windows 10/11 SDK not found under Windows Kits')
                self.toolchain = {'visual_studio': str(studio), 'visual_studio_version': year,
                                  'msvc_toolset': toolsets[-1].name, 'windows_sdk': sdks[-1]}
                return studio, year
        raise InvalidArtifact('Visual Studio 2026/2022 with the C++ toolset not found; set GYP_MSVS_OVERRIDE_PATH')

    def depot_tool(self, name):
        return self.depot / (f'{name}.bat' if self.windows else name)

    def python(self):
        # depot_tools bootstraps its own CPython on Windows; hooks and GN expect it.
        return self.depot_tool('python3') if self.windows else 'python3'

    # -- stages -------------------------------------------------------------
    def resolve(self, version):
        require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'invalid Flutter stable version')
        require(version in (REPO / 'supported_versions.txt').read_text().split(), f'unsupported Flutter version: {version}')
        sdk = self.cache / f'flutter-{version}'
        self.cache.mkdir(parents=True, exist_ok=True)
        if not sdk.is_dir():
            self.run('git', 'clone', '--depth', '1', '--branch', version, FLUTTER_REMOTE, sdk)
        require(self.git(sdk, 'remote', 'get-url', 'origin') == FLUTTER_REMOTE, 'unexpected Flutter source remote')
        require(not self.git(sdk, 'status', '--porcelain', '--untracked-files=no'), 'managed Flutter SDK has tracked edits')
        self.run('git', '-C', sdk, 'fetch', '--depth', '1', 'origin', f'refs/tags/{version}')
        tag_commit = self.git(sdk, 'rev-parse', 'FETCH_HEAD')
        self.run('git', '-C', sdk, 'checkout', '--detach', tag_commit)
        commit = (sdk / 'bin/internal/engine.version').read_text().strip()
        require(re.fullmatch(r'[0-9a-f]{40}', commit), 'invalid engine.version')
        stamp = commit
        if (sdk / 'bin/cache/engine.stamp').is_file():
            stamp = (sdk / 'bin/cache/engine.stamp').read_text().strip()
        require(re.fullmatch(r'[0-9a-f]{40}', stamp), 'invalid engine.stamp')
        resolved = {'flutter_version': version, 'engine_commit': commit, 'engine_stamp': stamp,
                    'flutter_sdk': str(sdk), 'framework_commit': tag_commit}
        write_json(self.run_dir / 'resolved.json', resolved)
        return resolved

    def fetch(self, commit):
        depot_rev = (REPO / 'DEPOT_TOOLS_REV').read_text().strip()
        require(re.fullmatch(r'[0-9a-f]{40}', depot_rev), 'invalid DEPOT_TOOLS_REV')
        self.cache.mkdir(parents=True, exist_ok=True)
        if not self.depot.is_dir():
            self.run('git', 'clone', DEPOT_REMOTE, self.depot)
        require(self.git(self.depot, 'remote', 'get-url', 'origin') == DEPOT_REMOTE, 'unexpected depot_tools remote')
        require(not self.git(self.depot, 'status', '--porcelain', '--untracked-files=no'), 'depot_tools has tracked edits')
        self.run('git', '-C', self.depot, 'fetch', 'origin', depot_rev)
        self.run('git', '-C', self.depot, 'checkout', '--detach', depot_rev)
        require(self.git(self.depot, 'rev-parse', 'HEAD') == depot_rev, 'depot_tools commit mismatch')
        if self.windows:
            # One-time CPython/CIPD bootstrap that update_depot_tools.bat would otherwise run.
            self.run('cmd', '/c', self.depot / 'bootstrap/win_tools.bat')
            require(self.depot_tool('python3').is_file(), 'depot_tools python3 bootstrap failed')
        if not self.engine.is_dir():
            self.run('git', 'init', self.engine)
            self.run('git', '-C', self.engine, 'remote', 'add', 'origin', FLUTTER_REMOTE)
        require(self.git(self.engine, 'remote', 'get-url', 'origin') == FLUTTER_REMOTE, 'unexpected engine source remote')
        self.revert_previous_patch()
        if subprocess.run(['git', '-C', str(self.engine), 'rev-parse', '--verify', 'HEAD'],
                          capture_output=True).returncode == 0:
            check_clean(self.engine)
        self.run('git', '-C', self.engine, 'fetch', '--depth', '1', 'origin', commit)
        self.run('git', '-C', self.engine, 'checkout', '--detach', commit)
        require(self.git(self.engine, 'rev-parse', 'HEAD') == commit, 'engine commit mismatch')
        shutil.copyfile(self.engine / 'engine/scripts/standard.gclient', self.engine / '.gclient')
        self.run(self.depot_tool('gclient'), 'sync', '-D', '--no-history', cwd=self.engine)
        require(self.git(self.engine, 'rev-parse', 'HEAD') == commit, 'engine commit changed during sync')
        require(self.git(self.depot, 'rev-parse', 'HEAD') == depot_rev, 'depot_tools changed during sync')
        check_clean(self.engine)

    def revert_previous_patch(self):
        """Undo exactly the patch a previous run applied; unknown edits stop the job."""
        previous = self.cache / 'applied.patch'
        if not previous.is_file():
            return
        dart = self.src / 'flutter/third_party/dart'
        require((dart / '.git').exists(), 'recorded patched Dart checkout missing')
        current = self.git(dart, 'diff', '--full-index', '--binary', 'HEAD')
        require(current == read_patch(previous), 'cached patch differs from recorded patch')
        self.run('git', '-C', dart, 'apply', '--reverse', '--check', previous)
        self.run('git', '-C', dart, 'apply', '--reverse', previous)
        previous.unlink()

    def apply_patches(self):
        require(not (self.cache / 'applied.patch').exists(), 'fetch must leave an unpatched checkout')
        dart = self.src / 'flutter/third_party/dart'
        patches = sorted((REPO / 'engine_patches').glob('*.patch'))
        require(bool(patches), 'no engine patches')
        self.run('git', '-C', dart, 'apply', '--check', *patches)
        self.run('git', '-C', dart, 'apply', *patches)
        applied = self.git(dart, 'diff', '--full-index', '--binary', 'HEAD')
        require(bool(applied), 'engine patches made no changes')
        write_patch(self.cache / 'applied.patch', applied)
        return applied

    def check_windows_sdk(self):
        """The engine pins one Windows SDK for local builds; fail before GN if it is absent."""
        setup = (self.src / 'build/toolchain/win/setup_toolchain.py').read_text(encoding='utf-8')
        pinned = re.search(r"^SDK_VERSION = '([0-9.]+)'$", setup, re.M)
        require(pinned is not None, 'cannot read the pinned Windows SDK version from setup_toolchain.py')
        kits = Path(self.env.get('PROGRAMFILES(X86)', 'C:/Program Files (x86)')) / 'Windows Kits/10/Include'
        require((kits / pinned.group(1)).is_dir(),
                f'Windows SDK {pinned.group(1)} is required by this engine (winget install '
                f'--id Microsoft.WindowsSDK.{pinned.group(1)[:-2]}); installed: '
                + ', '.join(p.name for p in kits.glob('10.*')))
        self.toolchain['windows_sdk'] = pinned.group(1)
        # GN's default toolchain copies the target CPU's CRT and debugger DLLs
        # even for an Android arm64 build, so the VS "ARM64 build tools"
        # component and the SDK "Debugging Tools for Windows" must be present.
        studio = Path(self.toolchain['visual_studio'])
        require(any((studio / 'VC/Redist/MSVC').glob('*/arm64/*/msvcp140.dll')),
                'Visual Studio component VC.Tools.ARM64 (ARM64 build tools, provides the arm64 CRT redist) is missing')
        require((kits.parent / 'Debuggers/arm64/dbghelp.dll').is_file(),
                'Windows SDK feature "Debugging Tools for Windows" (OptionId.WindowsDesktopDebuggers) is missing')

    def build_snapshot(self, jobs):
        target, output = hosts.GEN_SNAPSHOT_BUILD[self.host]
        if self.windows:
            self.check_windows_sdk()
        self.run(self.python(), self.src / 'flutter/tools/gn', *GN_ARGS, cwd=self.src)
        args = (self.src / OUT / 'args.gn').read_text()
        require(re.search(r'^dart_dynamic_modules = true$', args, re.M), 'dart_dynamic_modules is not true')
        # DEPS places ninja at the checkout root (third_party/ninja), beside .gclient.
        ninja = self.engine / 'third_party/ninja' / hosts.exe(self.host, 'ninja')
        require(ninja.is_file(), f'ninja missing from the DEPS checkout: {ninja}')
        self.run(ninja, '-C', self.src / OUT, '-j', jobs, target, cwd=self.src)
        binary = self.src / OUT / output
        require(binary.is_file() and binary.stat().st_size > 0, f'build artifact missing: {output}')
        version = self.run(binary, '--version', capture=True)
        require('Dart' in version, 'gen_snapshot --version failed')
        return binary

    def sdk_ready(self, sdk):
        flutter = hosts.flutter_launcher(self.host, sdk)
        self.run(flutter, '--suppress-analytics', 'precache', '--android')
        self.run(flutter, '--suppress-analytics', '--version', '--machine', capture=True)

    def compile_fixture(self, sdk, gen_snapshot, work):
        """The minimal AOT snapshot used by verify_pair.sh, compiled with `gen_snapshot`."""
        work.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / 'engine/fixtures/pair/main.dart', work / 'main.dart')
        (work / 'package_config.json').write_text('{"configVersion":2,"packages":[]}\n')
        frontend = sdk / hosts.toolchain_file(self.host, 'frontend_server_aot.dart.snapshot')
        self.run(hosts.dart_binary(self.host, sdk, 'dartaotruntime'), frontend,
                 '--sdk-root', str(sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product') + '/',
                 '--target', 'flutter', '--target-os', 'android', '--aot', '--tfa',
                 '--packages', work / 'package_config.json', '--output-dill', work / 'main.dill', work / 'main.dart')
        require((work / 'main.dill').stat().st_size > 0, 'minimal kernel not produced')
        self.run(gen_snapshot, '--snapshot_kind=app-aot-elf', f'--elf={work / "libapp.so"}', work / 'main.dill')
        with (work / 'libapp.so').open('rb') as stream:
            elf_machine(stream.read(20), 183, 'minimal AOT snapshot')

    def build(self, version, out, jobs):
        out = Path(out).resolve()
        require(not out.exists() or not any(out.iterdir()), 'output directory is not empty')
        require(not self.git(REPO, 'status', '--porcelain'), 'builder repository is dirty')
        builder_commit = self.git(REPO, 'rev-parse', 'HEAD')
        self.say(f'Host build {self.run_dir.name}: Flutter {version}, host {self.host}, builder {builder_commit}')
        resolved = self.resolve(version)
        self.fetch(resolved['engine_commit'])
        applied = self.apply_patches()
        binary = self.build_snapshot(jobs)
        require(self.git(self.src / 'flutter/third_party/dart', 'diff', '--full-index', '--binary', 'HEAD') == applied,
                'source patch changed during build')
        require(self.git(REPO, 'rev-parse', 'HEAD') == builder_commit and not self.git(REPO, 'status', '--porcelain'),
                'builder repository changed during build')
        sdk = Path(resolved['flutter_sdk'])
        self.sdk_ready(sdk)
        self.compile_fixture(sdk, binary, self.run_dir / 'verify')
        out.mkdir(parents=True, exist_ok=True)
        name = hosts.gen_snapshot_name(self.host)
        shutil.copyfile(binary, out / name)
        host_os, host_arch = hosts.split(self.host)
        bundle = {
            'schema': 1, 'kind': 'host_snapshot', 'host_os': host_os, 'host_arch': host_arch,
            'flutter_version': version, 'engine_commit': resolved['engine_commit'],
            'engine_stamp': resolved['engine_stamp'], 'builder_repo_commit': builder_commit,
            'depot_tools_rev': (REPO / 'DEPOT_TOOLS_REV').read_text().strip(),
            'patches': patch_records(REPO),
            'built_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'file': {'name': name, 'size': (out / name).stat().st_size, 'sha256': sha256(out / name)},
            'verify': {'snapshot': 'passed'}, 'toolchain': self.toolchain, 'run': self.run_dir.name,
        }
        write_json(out / 'host.manifest.json', bundle)
        validate_bundle(out)
        self.say(f'HOST_SNAPSHOT_READY: {out}')

    def attach(self, release, bundle_dir):
        release = Path(release).resolve()
        manifest = attach(release, bundle_dir)
        bundle = validate_bundle(bundle_dir)
        host = hosts.key(bundle['host_os'], bundle['host_arch'])
        if host != self.host:
            self.say(f'ATTACHED_WITHOUT_PAIRING: {host} gen_snapshot cannot run on {self.host}')
            return
        sdk = Path(self.resolve(manifest['flutter_version'])['flutter_sdk'])
        self.sdk_ready(sdk)
        work = self.run_dir / 'pair'
        self.compile_fixture(sdk, release / hosts.gen_snapshot_name(host), work)
        import pair_device
        pair_device.verify(release, sdk, work)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--home', default=os.environ.get('WP1_HOME') or str(Path.home() / '.flutter_patcher/engine-builder'))
    commands = parser.add_subparsers(dest='command', required=True)
    fetch = commands.add_parser('fetch')
    fetch.add_argument('version')
    build = commands.add_parser('build')
    build.add_argument('version')
    build.add_argument('--out', required=True)
    build.add_argument('--jobs', type=int, default=int(os.environ.get('WP1_JOBS', '0')) or max(2, (os.cpu_count() or 4) // 2))
    add = commands.add_parser('attach')
    add.add_argument('release')
    add.add_argument('bundle')
    args = parser.parse_args()
    pipeline = None
    try:
        pipeline = Pipeline(args.home)
        if args.command == 'fetch':
            pipeline.fetch(pipeline.resolve(args.version)['engine_commit'])
        elif args.command == 'build':
            pipeline.build(args.version, args.out, args.jobs)
        else:
            pipeline.attach(args.release, args.bundle)
    except (InvalidArtifact, OSError, ValueError, KeyError, subprocess.CalledProcessError, hosts.HostError) as error:
        print(f'HOST_SNAPSHOT_FAILED: {error}', file=sys.stderr)
        return 1
    finally:
        if pipeline is not None:
            pipeline.log.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
