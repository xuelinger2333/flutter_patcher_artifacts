#!/usr/bin/env python3
"""Packaging and manifest integrity checks; Python standard library only.

Manifest schema 2 carries one gen_snapshot per build host. The
primary host (linux-x64) packages libflutter.so, the embedding jar and its own
gen_snapshot under one build_id; secondary hosts build only a gen_snapshot from
the same engine commit and patches, verify it, and `attach` it to the release.
Schema 1 releases (single linux-x64 gen_snapshot) stay readable and are
upgraded in place by the first attach.
"""

import argparse
import copy
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import sys
import uuid
import zipfile

import hosts


class InvalidArtifact(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidArtifact(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f'duplicate JSON key: {key}')
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=unique)


def write_json(path, value):
    path = Path(path)
    pending = path.with_suffix(path.suffix + '.tmp')
    pending.write_bytes((json.dumps(value, indent=2, sort_keys=True) + '\n').encode('utf-8'))
    pending.replace(path)


def hex_value(value, length):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{%d}' % length, value)


def filename(value):
    return (isinstance(value, str) and value not in ('', '.', '..')
            and '/' not in value and '\\' not in value and ':' not in value)


def timestamp(value):
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value),
            'invalid built_at')
    datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')


def elf_machine(data, expected, name):
    require(len(data) >= 20 and data[:4] == b'\x7fELF', f'{name}: not ELF')
    require(data[4:6] == b'\x02\x01', f'{name}: expected ELF64 little endian')
    require(struct.unpack_from('<H', data, 18)[0] == expected,
            f'{name}: wrong ELF architecture')


def check_patches(value):
    require(isinstance(value, list) and len(value) > 0, 'missing patches')
    names = []
    for patch in value:
        require(isinstance(patch, dict) and filename(patch.get('file'))
                and patch['file'].endswith('.patch')
                and hex_value(patch.get('sha256'), 64), 'invalid patch record')
        names.append(patch['file'])
    require(names == sorted(set(names)), 'patch order/duplicates invalid')


def check_host_patches(value):
    """Host-only patches (engine_patches/<host>/) are optional and may be empty."""
    if value is None or value == []:
        return
    check_patches(value)


def check_verify(verify, what='verify'):
    require(isinstance(verify, dict), f'missing {what} result')
    require(verify.get('snapshot') in ('pending', 'passed'), f'{what}: invalid snapshot result')
    require(verify.get('device') in ('pending', 'passed', 'skipped'), f'{what}: invalid device result')
    if verify['device'] == 'skipped':
        require(verify.get('device_reason') == 'no_android_device', f'{what}: invalid device skip reason')
    else:
        require(verify.get('device_reason') is None, f'{what}: unexpected device reason')


def verified(verify):
    return verify['snapshot'] == 'passed' and verify['device'] in ('passed', 'skipped')


def host_of(record):
    try:
        return hosts.key(record.get('host_os'), record.get('host_arch'))
    except hosts.HostError as error:
        raise InvalidArtifact(str(error)) from error


def check_host_file(directory, record, host):
    """Size, hash and native-executable checks shared by releases and bundles."""
    require(record.get('name') == hosts.gen_snapshot_name(host), f'{host}: invalid gen_snapshot name')
    path = directory / record['name']
    require(path.is_file() and not path.is_symlink(), f'{host}: gen_snapshot missing')
    require(type(record.get('size')) is int and record['size'] > 0
            and path.stat().st_size == record['size'], f'{host}: size mismatch')
    require(hex_value(record.get('sha256'), 64) and sha256(path) == record['sha256'],
            f'{host}: SHA-256 mismatch')
    with path.open('rb') as stream:
        require(hosts.is_native_executable(host, stream.read(64)), f'{host}: not a native executable')
    return path


def check_toolchain(value):
    if value is not None:
        require(isinstance(value, dict) and all(
            isinstance(k, str) and isinstance(v, str) for k, v in value.items()), 'invalid toolchain record')


def check_snapshot_record(directory, record, schema, seen_hosts):
    host = host_of(record)
    require(host in hosts.SUPPORTED, f'unsupported gen_snapshot host: {host}')
    require(host not in seen_hosts, f'duplicate gen_snapshot host: {host}')
    seen_hosts.append(host)
    if schema == 1:
        require(host == hosts.PRIMARY, 'unsupported gen_snapshot host')
        require(set(record) <= {'role', 'name', 'size', 'sha256', 'host_os', 'host_arch'},
                'schema 1 gen_snapshot record has extra fields')
    else:
        check_verify(record.get('verify'), f'{host} verify')
        timestamp(record.get('built_at'))
        require(hex_value(record.get('builder_repo_commit'), 40), f'{host}: invalid builder commit')
        check_toolchain(record.get('toolchain'))
        check_host_patches(record.get('host_patches'))
    check_host_file(directory, record, host)


def check_jar_record(directory, record, role, engine_stamp):
    expected = {
        'engine': 'libflutter-arm64_v8a-release.jar',
        'embedding': 'flutter_embedding_release.jar',
    }
    require(record.get('name') == expected[role], f'{role}: invalid name')
    path = directory / record['name']
    require(path.is_file() and not path.is_symlink(), f'{role}: artifact missing')
    require(type(record.get('size')) is int and record['size'] > 0
            and path.stat().st_size == record['size'], f'{role}: size mismatch')
    require(hex_value(record.get('sha256'), 64)
            and sha256(path) == record['sha256'], f'{role}: SHA-256 mismatch')
    artifact_id = 'arm64_v8a_release' if role == 'engine' else 'flutter_embedding_release'
    require(record.get('maven') == f'io.flutter:{artifact_id}:1.0.0-{engine_stamp}',
            f'{role}: Maven coordinate mismatch')
    if role == 'engine':
        require(record.get('abi') == 'arm64-v8a', 'engine: unsupported ABI')
        with zipfile.ZipFile(path) as archive:
            member = 'lib/arm64-v8a/libflutter.so'
            require(archive.namelist() == [member], 'unexpected engine jar entries')
            data = archive.read(member)
            elf_machine(data, 183, member)
            require(record.get('contents') == [{
                'name': member, 'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)
            }], 'libflutter.so content metadata mismatch')
    else:
        with zipfile.ZipFile(path) as archive:
            require('io/flutter/embedding/engine/FlutterJNI.class' in archive.namelist(),
                    'embedding jar missing FlutterJNI')
            require(archive.testzip() is None, 'embedding jar CRC mismatch')


def validate(directory, publishable=False):
    directory = Path(directory)
    manifest = read_json(directory / 'engine.manifest.json')
    require(isinstance(manifest, dict), 'manifest must be a JSON object')
    schema = manifest.get('schema')
    require(type(schema) is int and schema in (1, 2), 'unsupported manifest schema')
    require(re.fullmatch(r'\d+\.\d+\.\d+', manifest.get('flutter_version', '')),
            'invalid Flutter stable version')
    for key in ('engine_commit', 'builder_repo_commit', 'depot_tools_rev'):
        require(hex_value(manifest.get(key), 40), f'invalid {key}')
    require(hex_value(manifest.get('engine_stamp'), 40), 'invalid engine_stamp')
    require(isinstance(manifest.get('build_id'), str), 'invalid build_id')
    build_id = uuid.UUID(manifest['build_id'])
    require(build_id.version == 4 and str(build_id) == manifest['build_id'],
            'build_id must be a canonical UUID v4')
    timestamp(manifest.get('built_at'))
    check_patches(manifest.get('patches'))
    files = manifest.get('files')
    require(isinstance(files, list), 'invalid files')
    if schema == 1:
        require(len(files) == 3, 'expected three artifacts')
    seen = set()
    snapshot_hosts = []
    for record in files:
        require(isinstance(record, dict), 'invalid file record')
        role = record.get('role')
        if role == 'gen_snapshot':
            check_snapshot_record(directory, record, schema, snapshot_hosts)
        else:
            require(role in ('engine', 'embedding') and role not in seen, 'missing/duplicate artifact role')
            seen.add(role)
            check_jar_record(directory, record, role, manifest['engine_stamp'])
    require(seen == {'engine', 'embedding'}, 'missing engine or embedding artifact')
    require(hosts.PRIMARY in snapshot_hosts, 'missing primary gen_snapshot')
    verify = manifest.get('verify')
    check_verify(verify)
    if 'supersedes' in manifest:
        require(re.fullmatch(r'engine-' + re.escape(manifest['flutter_version']) + r'(?:-r[2-9][0-9]*|-r1[0-9]+)?',
                            manifest['supersedes']), 'invalid supersedes')
    if publishable:
        require(verify['snapshot'] == 'passed', 'snapshot verification not passed')
        require(verify['device'] in ('passed', 'skipped'), 'device verification pending')
        for record in files:
            if record['role'] == 'gen_snapshot' and schema == 2:
                require(verified(record['verify']), f'{host_of(record)}: gen_snapshot verification pending')
        log = directory / 'build.log.zst'
        require(log.is_file() and log.stat().st_size > 0, 'missing compressed build log')
    return manifest


def snapshot_record(manifest, host):
    """The gen_snapshot record for `host`, or None."""
    for record in manifest['files']:
        if record['role'] == 'gen_snapshot' and host_of(record) == host:
            return record
    return None


def package(build_dir, identity_path, directory):
    """Primary-host packaging: engine jar, embedding jar and linux-x64 gen_snapshot."""
    build_dir, directory = Path(build_dir), Path(directory)
    identity = read_json(identity_path)
    require(identity.get('build_completed') is True, 'build has not completed')
    require(not directory.exists() or not any(directory.iterdir()), 'output directory is not empty')
    directory.mkdir(parents=True, exist_ok=True)
    host = hosts.PRIMARY
    engine = build_dir / 'lib.stripped/libflutter.so'
    embedding = build_dir / 'flutter_embedding_release.jar'
    snapshot = build_dir / hosts.GEN_SNAPSHOT_BUILD[host][1]
    sources = {'engine': engine, 'embedding': embedding, 'gen_snapshot': snapshot}
    require(identity.get('output_sha256') == {key: sha256(path) for key, path in sources.items()},
            'build outputs changed since successful build')
    manifest = {key: identity[key] for key in (
        'flutter_version', 'engine_commit', 'engine_stamp', 'build_id', 'built_at',
        'builder_repo_commit', 'depot_tools_rev', 'patches')}
    pending = {'snapshot': 'pending', 'device': 'pending', 'device_reason': None}
    manifest.update(schema=2, files=[], verify=dict(pending))
    engine_jar = directory / 'libflutter-arm64_v8a-release.jar'
    member = 'lib/arm64-v8a/libflutter.so'
    info = zipfile.ZipInfo(member, (1980, 1, 1, 0, 0, 0))
    info.external_attr = 0o100755 << 16
    info.compress_type = zipfile.ZIP_STORED
    with zipfile.ZipFile(engine_jar, 'w') as archive:
        archive.writestr(info, engine.read_bytes())
    shutil.copyfile(embedding, directory / 'flutter_embedding_release.jar')
    snapshot_name = hosts.gen_snapshot_name(host)
    shutil.copyfile(snapshot, directory / snapshot_name)
    (directory / snapshot_name).chmod(0o755)
    for role, name in (
        ('engine', engine_jar.name), ('embedding', 'flutter_embedding_release.jar'),
        ('gen_snapshot', snapshot_name)):
        path = directory / name
        record = {'role': role, 'name': name, 'size': path.stat().st_size, 'sha256': sha256(path)}
        if role == 'engine':
            record.update(abi='arm64-v8a',
                          maven=f'io.flutter:arm64_v8a_release:1.0.0-{manifest["engine_stamp"]}',
                          contents=[{'name': member, 'sha256': sha256(engine), 'size': engine.stat().st_size}])
        elif role == 'embedding':
            record['maven'] = f'io.flutter:flutter_embedding_release:1.0.0-{manifest["engine_stamp"]}'
        else:
            host_os, host_arch = hosts.split(host)
            record.update(host_os=host_os, host_arch=host_arch, verify=dict(pending),
                          built_at=manifest['built_at'], builder_repo_commit=manifest['builder_repo_commit'])
        manifest['files'].append(record)
    write_json(directory / 'engine.manifest.json', manifest)
    validate(directory)
    return manifest


def validate_bundle(directory):
    """A secondary host's output: one gen_snapshot plus host.manifest.json."""
    directory = Path(directory)
    bundle = read_json(directory / 'host.manifest.json')
    require(isinstance(bundle, dict), 'bundle manifest must be a JSON object')
    require(type(bundle.get('schema')) is int and bundle['schema'] == 1
            and bundle.get('kind') == 'host_snapshot', 'unsupported bundle schema')
    require(re.fullmatch(r'\d+\.\d+\.\d+', bundle.get('flutter_version', '')), 'invalid Flutter stable version')
    for key in ('engine_commit', 'engine_stamp', 'builder_repo_commit', 'depot_tools_rev'):
        require(hex_value(bundle.get(key), 40), f'invalid {key}')
    timestamp(bundle.get('built_at'))
    check_patches(bundle.get('patches'))
    host = host_of(bundle)
    require(host in hosts.SECONDARY, f'not a secondary host: {host}')
    record = bundle.get('file')
    require(isinstance(record, dict), 'missing file record')
    check_host_file(directory, record, host)
    verify = bundle.get('verify')
    require(isinstance(verify, dict) and verify.get('snapshot') in ('pending', 'passed'),
            'invalid snapshot result')
    check_toolchain(bundle.get('toolchain'))
    check_host_patches(bundle.get('host_patches'))
    return bundle


def attach(directory, bundle_dir):
    """Adds a verified secondary-host gen_snapshot to a release; upgrades schema 1 to 2."""
    directory, bundle_dir = Path(directory), Path(bundle_dir)
    manifest = validate(directory)
    bundle = validate_bundle(bundle_dir)
    for key in ('flutter_version', 'engine_commit', 'engine_stamp', 'depot_tools_rev', 'patches'):
        require(manifest[key] == bundle[key], f'bundle {key} does not match the release')
    require(bundle['verify']['snapshot'] == 'passed', 'bundle snapshot verification not passed')
    host = host_of(bundle)
    require(snapshot_record(manifest, host) is None, f'release already has a gen_snapshot for {host}')
    if manifest['schema'] == 1:
        primary = snapshot_record(manifest, hosts.PRIMARY)
        primary.update(verify=copy.deepcopy(manifest['verify']), built_at=manifest['built_at'],
                       builder_repo_commit=manifest['builder_repo_commit'])
        manifest['schema'] = 2
    name = bundle['file']['name']
    require(not (directory / name).exists(), f'{name} already exists in the release')
    shutil.copyfile(bundle_dir / name, directory / name)
    record = {'role': 'gen_snapshot', 'name': name, 'size': bundle['file']['size'],
              'sha256': bundle['file']['sha256'], 'host_os': bundle['host_os'],
              'host_arch': bundle['host_arch'], 'built_at': bundle['built_at'],
              'builder_repo_commit': bundle['builder_repo_commit'],
              'verify': {'snapshot': 'passed', 'device': 'pending', 'device_reason': None}}
    if bundle.get('toolchain') is not None:
        record['toolchain'] = bundle['toolchain']
    if bundle.get('host_patches'):
        record['host_patches'] = bundle['host_patches']
    original = read_json(directory / 'engine.manifest.json')
    manifest['files'].append(record)
    write_json(directory / 'engine.manifest.json', manifest)
    try:
        validate(directory)
    except InvalidArtifact:
        # Leave the release exactly as it was; a half-attached host is worse than none.
        (directory / name).unlink()
        write_json(directory / 'engine.manifest.json', original)
        raise
    return manifest


def comparable(manifest):
    result = copy.deepcopy(manifest)
    for key in ('build_id', 'built_at'):
        result.pop(key)
    for record in result['files']:
        record.pop('sha256')
        record.pop('built_at', None)
        for content in record.get('contents', []):
            content.pop('sha256')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    pack = commands.add_parser('package')
    pack.add_argument('--build-dir', required=True)
    pack.add_argument('--identity', required=True)
    pack.add_argument('--out', required=True)
    check = commands.add_parser('validate')
    check.add_argument('directory')
    check.add_argument('--publishable', action='store_true')
    compare = commands.add_parser('compare')
    compare.add_argument('first')
    compare.add_argument('second')
    add = commands.add_parser('attach')
    add.add_argument('release')
    add.add_argument('bundle')
    args = parser.parse_args()
    try:
        if args.command == 'package':
            package(args.build_dir, args.identity, args.out)
        elif args.command == 'validate':
            validate(args.directory, args.publishable)
        elif args.command == 'attach':
            attach(args.release, args.bundle)
        else:
            require(comparable(validate(args.first)) == comparable(validate(args.second)),
                    'repeated build manifest metadata differs')
    except (InvalidArtifact, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print(f'ENGINE_ARTIFACT_INVALID: {error}', file=sys.stderr)
        return 1
    print('OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
