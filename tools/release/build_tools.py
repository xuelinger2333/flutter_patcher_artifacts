#!/usr/bin/env python3
"""WP-1b: build stock-Dart tools twice, smoke-test, and enforce A11."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from tools_artifacts import compare, create, names, read_json, require, sha256, write_json

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'engine/scripts'))
import hosts  # noqa: E402

# The dill is host-independent; only the launcher, Dart binaries and the SDK
# toolchain directory differ per host (WP-2.6 phase C).
HOST = hosts.current()
SDK_PACKAGES = ('kernel', 'front_end', '_fe_analyzer_shared', 'vm', 'dart2bytecode', 'build_integration')


def run(*args, cwd=None, capture=False):
    print('+', *map(str, args), flush=True)
    result = subprocess.run(list(map(str, args)), cwd=cwd, text=True,
                            stdout=subprocess.PIPE if capture else None)
    if result.returncode:
        if result.stdout:
            print(result.stdout, flush=True)
        raise RuntimeError(f'Command failed ({result.returncode}): {args[0]}')
    return result.stdout.strip() if capture else None


def git(*args, cwd=REPO):
    return run('git', *args, cwd=cwd, capture=True)


def source_overrides(source, sdk):
    overrides = {}
    for name in SDK_PACKAGES:
        package = sdk / 'pkg' / name
        require((package / 'pubspec.yaml').is_file(), f'SDK package missing: {name}')
        # Official pub escape hatch: keep dependency packages out of the SDK's
        # development workspace without editing any upstream tracked source.
        (package / 'pubspec_overrides.yaml').write_text('resolution:\nworkspace: []\n')
        overrides[name] = {'path': os.path.relpath(package, source / 'tools/kernel_tools').replace(os.sep, '/')}
    write_json(source / 'tools/kernel_tools/pubspec_overrides.yaml', {'dependency_overrides': overrides})


def compile_fixtures(flutter, source):
    fixtures = source / 'tools/kernel_tools/test/fixtures'
    shutil.copytree(fixtures / 'shapes', fixtures / 'lib')
    run(hosts.flutter_launcher(HOST, flutter), '--suppress-analytics', 'pub', 'get', cwd=fixtures)
    platform = flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product'
    frontend = flutter / hosts.toolchain_file(HOST, 'frontend_server_aot.dart.snapshot')
    output = fixtures / '.dart_tool/flutter_patcher'
    output.mkdir(parents=True)
    for i in range(1, 10):
        run(hosts.dart_binary(HOST, flutter, 'dartaotruntime'), frontend,
            '--sdk-root', str(platform) + '/', '--target', 'flutter',
            '--no-aot', '--no-tfa', '--link-platform',
            '--packages', fixtures / '.dart_tool/package_config.json',
            '--output-dill', output / f'shape{i}.dill',
            f'package:shape_fixtures/shape{i}.dart', cwd=fixtures)
        require((output / f'shape{i}.dill').is_file(), f'Fixture {i} not compiled')
    return output


def check_compiler_help(help_text):
    require('--[no-]tfa' in help_text and '--[no-]aot-only' in help_text, 'Patched compiler flags missing')


def smoke(dart, release, version, fixtures, answers):
    outputs = names(version)
    help_text = run(dart, release / outputs['tools'], '--help', capture=True)
    require('detect-shape' in help_text, 'kernel-tools --help failed')
    help_text = run(dart, release / outputs['tools'], 'bytecode', '--help', capture=True)
    check_compiler_help(help_text)
    results = []
    import json
    for case in answers:
        text = run(dart, release / outputs['tools'], 'detect-shape',
                   '--dill', fixtures / (case['name'] + '.dill'), '--own', 'shape_fixtures',
                   '--exclude', 'f6_overlay.dart', capture=True)
        result = json.loads(text)
        require(result['verdict'] == case['verdict'], f"Wrong verdict: {case['name']}")
        require(len(result['injectionPoints']) == case['injection_points'], f"Wrong injection count: {case['name']}")
        require(len(result['bypasses']) == case['bypasses'], f"Wrong bypass count: {case['name']}")
        results.append({'name': case['name'], **result})
    return results


def compiler_smoke(dart, release, version, source, flutter, work):
    # A real no-main dynamic module exercises the F4 compiler path, beyond help.
    import json
    interface = work / 'compiler-interface.yaml'
    libraries = ['dart:core', 'dart:async', 'dart:collection', 'dart:convert',
                 'dart:io', 'dart:math', 'dart:typed_data', 'dart:isolate',
                 'dart:developer', 'dart:ffi', 'dart:_internal', 'dart:ui']
    interface.write_text(json.dumps({section: [{'library': lib} for lib in libraries]
                          for section in ['callable', 'extendable', 'can-be-overridden', 'can-be-used-as-type']}))
    for flag in ('--aot-only', '--tfa'):
        output = work / (flag[2:] + '.bytecode')
        run(dart, release / names(version)['tools'], 'bytecode',
            '--platform', flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
            '--target', 'flutter', '--validate', interface, flag, '-o', output,
            source / 'tools/kernel_tools/test/fixtures/compiler_module.dart')
        require(output.is_file() and output.stat().st_size > 0, 'Compiler smoke produced no bytecode')


def transform_smoke(dart, release, version, fixtures, work):
    import json
    snapshot = release / names(version)['tools']
    for index, count, verdict in ((4, 2, 'INJECTABLE'), (7, 1, 'INJECTABLE_HOLE')):
        output = work / f'transformed-shape{index}.dill'
        result = json.loads(run(dart, snapshot, 'transform-overlay', '--dill', fixtures / f'shape{index}.dill',
                            '--own', 'shape_fixtures', '--out', output,
                            '--helper-lib', 'package:shape_fixtures/f6_overlay.dart',
                            '--helper-fn', 'patcherOverlayBundle', capture=True))
        require(result == {'wrapped': count}, 'Wrong transformed injection count')
        result = json.loads(run(dart, snapshot, 'detect-shape', '--dill', output, '--own', 'shape_fixtures',
                                '--exclude', 'f6_overlay.dart', capture=True))
        require(result['verdict'] == verdict, 'Transformation changed resource-bypass classification')


def partition_smoke(dart, release, version, flutter, fixtures, work):
    """WP-2.5: partition generation is deterministic and structurally complete."""
    import json
    tool = release / names(version)['tools']
    platform = flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill'
    first = work / 'framework-partition-a.json'
    second = work / 'framework-partition-b.json'
    for output in (first, second):
        run(dart, tool, 'gen-framework-partition', '--platform', platform,
            '--dill', fixtures / 'shape1.dill', '--flutter-version', version,
            '--out', output)
    a, b = json.loads(first.read_text()), json.loads(second.read_text())
    require(a == b, 'Framework partition output is not deterministic')
    require(a['schema'] == 1 and isinstance(a['host'], list) and
            isinstance(a['carry'], list) and isinstance(a['libraries'], list),
            'Framework partition metadata is incomplete')
    return {'schema': a['schema'], 'host': len(a['host']), 'carry': len(a['carry']),
            'sha256': sha256(first)}


def baseline_smoke(dart, tool, flutter, source, work):
    """Verify the CI-built dill can emit an unlinked application kernel."""
    fixtures = source / 'tools/kernel_tools/test/fixtures'
    output = work / 'baseline-smoke'
    output.mkdir()
    packages = fixtures / '.dart_tool/package_config.json'
    run(dart, tool, 'compile-baseline', '--platform',
        flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
        '--target', 'flutter', '--no-aot', '--no-tfa', '--no-link-platform',
        '--packages', packages, '--output', output / 'app.dill',
        'package:shape_fixtures/shape1.dart', cwd=fixtures)
    run(dart, tool, 'inspect-build', '--dill', output / 'app.dill',
        '--packages', packages, '--out', output)
    require(read_json(output / 'kernel_receipt.json')['app_only'] is True,
            'Baseline unexpectedly links platform libraries')


def build(args):
    require(HOST in hosts.SUPPORTED, f'WP-1b build host not in the support matrix: {HOST}')
    versions = (REPO / 'supported_versions.txt').read_text().splitlines()
    require(args.version in versions, 'Unsupported Flutter version')
    pin = read_json(REPO / 'tools/versions.json')[args.version]
    require(not git('status', '--porcelain', '--untracked-files=normal'), 'Commit source changes before building')
    commit = git('rev-parse', 'HEAD')
    flutter = args.flutter.resolve()
    # FLUTTER_PATCHER_MANAGED lets a runner keep the managed stock SDK and work
    # tree off the profile drive (Windows); the containment rules are unchanged.
    managed = Path(os.environ.get('FLUTTER_PATCHER_MANAGED') or Path.home() / '.flutter_patcher')
    require(flutter.is_relative_to(managed.resolve()), 'Use a managed stock Flutter under ~/.flutter_patcher')
    work, output = args.work.resolve(), args.out.resolve()
    require(work.is_relative_to(managed.resolve()) or work.is_relative_to(REPO / '.dart_tool/flutter_patcher'),
            'Work must be under ~/.flutter_patcher or repository .dart_tool/flutter_patcher')
    require(not work.exists() and not output.exists(), 'Work and output must be new directories')
    require(not output.is_relative_to(work), 'Keep --out outside the work directory')
    work.mkdir(parents=True)
    os.environ['PUB_CACHE'] = str(work / 'pub-cache')
    start = time.monotonic()
    metadata = read_flutter(flutter)
    require(metadata['frameworkVersion'] == args.version, 'Flutter version mismatch')
    require(metadata['engineRevision'] == pin['engine_commit'], 'Flutter engine mismatch')
    require(metadata['dartSdkVersion'].split()[0] == pin['dart_version'], 'Dart version mismatch')
    require((flutter / 'bin/internal/engine.version').read_text().strip() == pin['engine_commit'], 'engine.version mismatch')
    source = work / 'source'
    source.mkdir()
    for name in ('tools',):
        shutil.copytree(REPO / name, source / name, ignore=shutil.ignore_patterns('__pycache__', '.dart_tool'))
    sdk = work / 'dart-sdk'
    run('git', 'clone', '--depth', '1', '--branch', pin['dart_version'], 'https://github.com/dart-lang/sdk.git', sdk)
    require(git('rev-parse', 'HEAD', cwd=sdk) == pin['dart_commit'], 'Dart tag commit drift')
    patches = sorted((source / 'tools/dart2bytecode_patches').glob('*.patch'))
    require(bool(patches), 'Missing reviewed tool patch')
    for patch in patches:
        run('git', 'apply', '--check', patch, cwd=sdk)
        run('git', 'apply', patch, cwd=sdk)
    expected_diff = git('diff', '--full-index', '--binary', cwd=sdk)
    source_overrides(source, sdk)
    package = source / 'tools/kernel_tools'
    shutil.copyfile(source / f'tools/locks/{args.version}.lock', package / 'pubspec.lock')
    dart = hosts.dart_binary(HOST, flutter)
    run(dart, 'pub', 'get', '--enforce-lockfile', cwd=package)
    config = package / '.dart_tool/package_config.json'
    run(dart, f'--packages={config}', package / 'test/detect_shape_test.dart', cwd=package)
    run(dart, f'--packages={config}', package / 'test/interface_test.dart', cwd=package)
    run(dart, f'--packages={config}', package / 'test/build_inspection_test.dart', cwd=package)
    run(dart, f'--packages={config}', package / 'test/patch_checks_test.dart', cwd=package)
    run(dart, f'--packages={config}', package / 'test/framework_partition_test.dart', cwd=package)
    run(hosts.flutter_launcher(HOST, flutter), '--suppress-analytics', 'precache', '--android')
    fixtures = compile_fixtures(flutter, source)
    answers = read_json(package / 'test/fixtures/expected.json')
    require(len(answers) == 9, 'Nine fixture answers required')
    patches_record = [{'file': p.name, 'sha256': sha256(p)} for p in patches]
    run(sys.executable, REPO / 'tools/generators/protocol_set/embed_definitions.py', '--check')
    for attempt in ('first', 'second'):
        release = work / attempt
        release.mkdir()
        files = names(args.version)
        run(dart, 'compile', 'kernel', 'bin/main.dart', '-o', release / files['tools'], cwd=package)
        # Generator smoke outputs are build evidence, never release assets.
        run(dart, release / files['tools'], 'gen-protocol-interface',
            '--dill', fixtures / 'shape1.dill', '--out', work / f'{attempt}-protocol.yaml')
        run(dart, release / files['tools'], 'gen-platform-privates',
            '--platform', flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
            '--out', work / f'{attempt}-privates.yaml')
        results = smoke(dart, release, args.version, fixtures, answers)
        write_json(work / f'{attempt}-smoke.json', results)
        create(release, args.version, metadata, commit, pin['dart_commit'], patches_record)
    compare(work / 'first', work / 'second')
    transform_smoke(dart, work / 'first', args.version, fixtures, work)
    partition_verification = partition_smoke(dart, work / 'first', args.version,
                                             flutter, fixtures, work)
    baseline_smoke(dart, work / 'first' / names(args.version)['tools'], flutter, source, work)
    from patch_smoke import exercise as exercise_patch
    patch_verification = exercise_patch(dart, work / 'first' / names(args.version)['tools'],
                                       flutter, work / 'baseline-smoke/app.dill', work / 'patch-smoke',
                                       packages=source / 'tools/kernel_tools/test/fixtures/.dart_tool/package_config.json',
                                       four_check_source=source / 'tools/kernel_tools/test/fixtures/patch/four_checks.dart')
    run(dart, f'--packages={config}', source / 'tools/release/resource_smoke.dart',
        work, work / 'first' / names(args.version)['tools'], work / 'baseline-smoke', flutter,
        source / 'tools/kernel_tools/test/fixtures/resources/overlay.dart',
        source / 'tools/kernel_tools/test/fixtures/.dart_tool/package_config.json')
    resource_verification = read_json(work / 'tool-smoke.json')
    compiler_smoke(dart, work / 'first', args.version, source, flutter, work)
    from fault_modules import build as build_fault_modules
    build_fault_modules(dart, work / 'first' / names(args.version)['tools'],
                        flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
                        work / 'compiler-interface.yaml', 'a' * 64, 7, work / 'fault-modules')
    from interface_smoke import exercise
    interface_verification = exercise(dart, work / 'first' / names(args.version)['tools'],
                                     flutter, fixtures, source, work / 'interfaces')
    require(git('diff', '--full-index', '--binary', cwd=sdk) == expected_diff, 'Dart source changed during build')
    require(git('rev-parse', 'HEAD') == commit and not git('status', '--porcelain'), 'Builder source changed during build')
    elapsed = round(time.monotonic() - start, 2)
    write_json(work / 'verification.json', {'a11': 'passed', 'snapshot_smoke': 'passed_9_of_9',
               'kernel_tools_help': 'passed', 'dart2bytecode_help': 'passed',
               'dart2bytecode_compilation': 'passed_aot_only_and_tfa', 'elapsed_seconds': elapsed,
               'builder_repo_commit': commit, 'flutter_version': args.version,
               'interfaces': interface_verification, 'patch': patch_verification,
               'resources': resource_verification,
               'framework_partition': partition_verification,
               'fault_modules': read_json(work / 'fault-modules/modules.json')})
    shutil.copytree(work / 'first', output)
    print(f'TOOLS_RELEASE_READY: {output}; A11 passed; {elapsed} seconds', flush=True)


def read_flutter(flutter):
    import json
    return json.loads(run(hosts.flutter_launcher(HOST, flutter), '--suppress-analytics', '--version', '--machine', capture=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('--flutter', required=True, type=Path)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    build(parser.parse_args())
