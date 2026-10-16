#!/usr/bin/env python3
"""Build-host identity shared by the engine and tools pipelines.

Mirrors `HostIdentity` in the CLI: `os` is `linux`, `windows` or `macos`,
`arch` is `x64` or `arm64`, and the Flutter SDK toolchain directory spells
macOS as `darwin`. Everything host-specific in the Python pipeline (artifact
names, executable suffixes, GN output paths, magic numbers) is derived here.
"""
import platform
import struct
import sys

# Primary host: builds libflutter.so together with its own gen_snapshot and
# owns the release build_id. Secondary hosts only add a gen_snapshot.
PRIMARY = 'linux-x64'
SECONDARY = ('windows-x64', 'macos-arm64')
SUPPORTED = (PRIMARY,) + SECONDARY

# Where the Android arm64 release build leaves the host gen_snapshot, and the
# Ninja target that produces it. Windows copies the host-toolchain output to
# `gen_snapshot/` (engine/src/flutter/BUILD.gn); the others expose the host
# toolchain directory directly.
GEN_SNAPSHOT_BUILD = {
    'linux-x64': ('clang_x64/gen_snapshot', 'clang_x64/gen_snapshot'),
    'windows-x64': ('flutter:gen_snapshot', 'gen_snapshot/gen_snapshot.exe'),
    'macos-arm64': ('clang_arm64/gen_snapshot', 'clang_arm64/gen_snapshot'),
}


class HostError(ValueError):
    pass


def key(host_os, host_arch):
    """Validates a manifest `host_os`/`host_arch` pair and returns `os-arch`."""
    if host_os not in ('linux', 'windows', 'macos') or host_arch not in ('x64', 'arm64'):
        raise HostError(f'invalid host: {host_os!r}/{host_arch!r}')
    return f'{host_os}-{host_arch}'


def split(host):
    host_os, host_arch = host.split('-', 1)
    key(host_os, host_arch)
    return host_os, host_arch


def current():
    host_os = {'linux': 'linux', 'win32': 'windows', 'darwin': 'macos'}.get(sys.platform)
    machine = platform.machine().lower()
    host_arch = {'x86_64': 'x64', 'amd64': 'x64', 'arm64': 'arm64', 'aarch64': 'arm64'}.get(machine)
    if host_os is None or host_arch is None:
        raise HostError(f'unsupported build host: {sys.platform}/{machine}')
    return key(host_os, host_arch)


def toolchain_dir(host):
    """Flutter SDK host toolchain directory: linux-x64, windows-x64, darwin-arm64."""
    host_os, host_arch = split(host)
    return f'{"darwin" if host_os == "macos" else host_os}-{host_arch}'


def exe(host, name):
    return f'{name}.exe' if host.startswith('windows-') else name


def script(host, name):
    return f'{name}.bat' if host.startswith('windows-') else name


def gen_snapshot_name(host):
    """Release asset name: gen_snapshot-<toolchain dir>[.exe]."""
    return exe(host, f'gen_snapshot-{toolchain_dir(host)}')


def gen_snapshot_install(host):
    """SDK-relative path where `flutter build apk` loads the AOT compiler."""
    return f'bin/cache/artifacts/engine/android-arm64-release/{toolchain_dir(host)}/{exe(host, "gen_snapshot")}'


def toolchain_file(host, name):
    return f'bin/cache/artifacts/engine/{toolchain_dir(host)}/{name}'


def flutter_launcher(host, sdk):
    return sdk / 'bin' / script(host, 'flutter')


def dart_binary(host, sdk, name='dart'):
    return sdk / 'bin/cache/dart-sdk/bin' / exe(host, name)


def is_native_executable(host, data):
    """First-bytes check that `data` is an executable for `host`."""
    if len(data) < 20:
        return False
    host_os, host_arch = split(host)
    if host_os == 'linux':
        machine = 183 if host_arch == 'arm64' else 62
        return (data[:4] == b'\x7fELF' and data[4:6] == b'\x02\x01'
                and struct.unpack_from('<H', data, 18)[0] == machine)
    if host_os == 'windows':
        return data[:2] == b'MZ'
    return data[:4] == b'\xcf\xfa\xed\xfe'
