#!/usr/bin/env python3
"""Install a dedicated smoke app with the published engine and its AOT snapshot."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import zipfile

from artifacts import elf_machine, require, validate, write_json


def run(*args, capture=False, cwd=None, env=None):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def connected_devices(output):
    lines = [line.split() for line in output.splitlines()[1:] if line.strip()]
    devices = [parts[0] for parts in lines if len(parts) >= 2 and parts[1] == 'device']
    require(not lines or devices, 'Android devices are offline or unauthorized; device verification cannot be skipped')
    return devices


def verify(release, sdk, work):
    release, sdk, work = Path(release), Path(sdk), Path(work)
    manifest = validate(release)
    require((work / 'libapp.so').is_file(), 'minimal snapshot missing')
    with (work / 'libapp.so').open('rb') as snapshot:
        elf_machine(snapshot.read(20), 183, 'minimal AOT snapshot')
    adb = shutil.which('adb')
    devices = connected_devices(run(adb, 'devices', capture=True)) if adb else []
    if not devices:
        manifest['verify'] = {'snapshot': 'passed', 'device': 'skipped',
                              'device_reason': 'no_android_device'}
        write_json(release / 'engine.manifest.json', manifest)
        print('DEVICE_SKIPPED: no_android_device; snapshot compilation passed')
        return
    # A connected but incompatible device is a failure, not an unavailable device.
    serial = os.environ.get('ANDROID_SERIAL')
    require(serial in devices if serial else len(devices) == 1,
            'set ANDROID_SERIAL when more than one device is connected')
    serial = serial or devices[0]
    command = [adb, '-s', serial]
    abis = run(*command, 'shell', 'getprop', 'ro.product.cpu.abilist', capture=True).strip().split(',')
    require('arm64-v8a' in abis, 'device does not support arm64-v8a')
    env = dict(os.environ)
    env.pop('FLUTTER_STORAGE_BASE_URL', None)
    app = work / 'app'
    run(sdk / 'bin/flutter', '--suppress-analytics', 'create', '--platforms=android',
        '--org=dev.flutterpatcher.wp1', '--project-name=engine_pair', app, env=env)
    shutil.copyfile(work / 'main.dart', app / 'lib/main.dart')
    run(sdk / 'bin/flutter', '--suppress-analytics', 'build', 'apk', '--release',
        '--target-platform=android-arm64', cwd=app, env=env)
    original = app / 'build/app/outputs/flutter-apk/app-release.apk'
    unsigned = work / 'pair-unsigned.apk'
    with zipfile.ZipFile(release / 'libflutter-arm64_v8a-release.jar') as archive:
        engine = archive.read('lib/arm64-v8a/libflutter.so')
    replacements = {'lib/arm64-v8a/libflutter.so': engine,
                    'lib/arm64-v8a/libapp.so': (work / 'libapp.so').read_bytes()}
    with zipfile.ZipFile(original) as source, zipfile.ZipFile(unsigned, 'w') as target:
        require(all(name in source.namelist() for name in replacements), 'APK native entry missing')
        for entry in source.infolist():
            if entry.filename.startswith('META-INF/'):
                continue
            if entry.filename in replacements:
                entry.compress_type = zipfile.ZIP_STORED
                target.writestr(entry, replacements[entry.filename])
            else:
                target.writestr(entry, source.read(entry.filename))
    android_sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
    require(bool(android_sdk), 'ANDROID_SDK_ROOT is required for device verification')
    candidates = sorted((Path(android_sdk) / 'build-tools').iterdir(),
                        key=lambda path: tuple(int(part) for part in path.name.split('.') if part.isdigit()))
    require(bool(candidates), 'Android build-tools missing')
    build_tools = candidates[-1]
    aligned, signed = work / 'pair-aligned.apk', work / 'pair-signed.apk'
    run(build_tools / 'zipalign', '-p', '-f', '4', unsigned, aligned)
    # Test-only key lives inside the pairing output, not in the user's key store.
    keystore = work / 'pair-test.jks'
    run('keytool', '-genkeypair', '-noprompt', '-keystore', keystore, '-storepass', 'android',
        '-keypass', 'android', '-alias', 'pair', '-keyalg', 'RSA', '-validity', '1',
        '-dname', 'CN=WP1 Test')
    run(build_tools / 'apksigner', 'sign', '--ks', keystore, '--ks-pass', 'pass:android',
        '--key-pass', 'pass:android', '--out', signed, aligned)
    package = 'dev.flutterpatcher.wp1.engine_pair'
    # This dedicated package is created by this verification only.
    run(*command, 'install', '-r', signed)
    try:
        run(*command, 'shell', 'am', 'force-stop', package)
        run(*command, 'shell', 'am', 'start', '-W', '-n', package + '/.MainActivity')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            pid = run(*command, 'shell', 'pidof', package, capture=True).strip()
            require(bool(pid), 'pair app exited')
            log = run(*command, 'logcat', '-d', '--pid=' + pid, '-v', 'brief', capture=True)
            (work / 'device.log').write_text(log)
            if 'WP1_PAIR_OK' in log:
                manifest['verify'] = {'snapshot': 'passed', 'device': 'passed', 'device_reason': None}
                write_json(release / 'engine.manifest.json', manifest)
                print('DEVICE_PAIR_PASSED')
                return
            time.sleep(1)
        raise ValueError('pair app did not render its first frame within 30 seconds')
    finally:
        run(*command, 'uninstall', package)


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 4, 'usage: pair_device.py <release> <sdk> <work>')
        verify(*sys.argv[1:])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'PAIR_VERIFICATION_FAILED: {error}', file=sys.stderr)
        sys.exit(1)
