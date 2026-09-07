#!/usr/bin/env python3
"""WP-1 packaging and manifest integrity checks; Python standard library only."""

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
    pending.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    pending.replace(path)


def hex_value(value, length):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{%d}' % length, value)


def filename(value):
    return (isinstance(value, str) and value not in ('', '.', '..')
            and '/' not in value and '\\' not in value and ':' not in value)


def elf_machine(data, expected, name):
    require(len(data) >= 20 and data[:4] == b'\x7fELF', f'{name}: not ELF')
    require(data[4:6] == b'\x02\x01', f'{name}: expected ELF64 little endian')
    require(struct.unpack_from('<H', data, 18)[0] == expected,
            f'{name}: wrong ELF architecture')


def validate(directory, publishable=False):
    directory = Path(directory)
    manifest = read_json(directory / 'engine.manifest.json')
    require(isinstance(manifest, dict), 'manifest must be a JSON object')
    require(type(manifest.get('schema')) is int and manifest['schema'] == 1,
            'unsupported manifest schema')
    require(re.fullmatch(r'\d+\.\d+\.\d+', manifest.get('flutter_version', '')),
            'invalid Flutter stable version')
    for key in ('engine_commit', 'builder_repo_commit', 'depot_tools_rev'):
        require(hex_value(manifest.get(key), 40), f'invalid {key}')
    require(hex_value(manifest.get('engine_stamp'), 40), 'invalid engine_stamp')
    require(isinstance(manifest.get('build_id'), str), 'invalid build_id')
    build_id = uuid.UUID(manifest['build_id'])
    require(build_id.version == 4 and str(build_id) == manifest['build_id'],
            'build_id must be a canonical UUID v4')
    require(re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z',
                        manifest.get('built_at', '')), 'invalid built_at')
    datetime.strptime(manifest['built_at'], '%Y-%m-%dT%H:%M:%SZ')
    patches = manifest.get('patches')
    require(isinstance(patches, list) and len(patches) > 0, 'missing patches')
    patch_names = []
    for patch in patches:
        require(isinstance(patch, dict) and filename(patch.get('file'))
                and patch['file'].endswith('.patch')
                and hex_value(patch.get('sha256'), 64), 'invalid patch record')
        patch_names.append(patch['file'])
    require(patch_names == sorted(set(patch_names)), 'patch order/duplicates invalid')
    files = manifest.get('files')
    require(isinstance(files, list) and len(files) == 3, 'expected three artifacts')
    expected = {
        'engine': 'libflutter-arm64_v8a-release.jar',
        'embedding': 'flutter_embedding_release.jar',
        'gen_snapshot': 'gen_snapshot-linux-x64',
    }
    seen = set()
    for record in files:
        require(isinstance(record, dict), 'invalid file record')
        role = record.get('role')
        require(role in expected and role not in seen, 'missing/duplicate artifact role')
        seen.add(role)
        require(record.get('name') == expected[role], f'{role}: invalid name')
        path = directory / record['name']
        require(path.is_file() and not path.is_symlink(), f'{role}: artifact missing')
        require(type(record.get('size')) is int and record['size'] > 0
                and path.stat().st_size == record['size'], f'{role}: size mismatch')
        require(hex_value(record.get('sha256'), 64)
                and sha256(path) == record['sha256'], f'{role}: SHA-256 mismatch')
        if role in ('engine', 'embedding'):
            artifact_id = 'arm64_v8a_release' if role == 'engine' else 'flutter_embedding_release'
            require(record.get('maven') == f'io.flutter:{artifact_id}:1.0.0-{manifest["engine_stamp"]}',
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
        elif role == 'embedding':
            with zipfile.ZipFile(path) as archive:
                require('io/flutter/embedding/engine/FlutterJNI.class' in archive.namelist(),
                        'embedding jar missing FlutterJNI')
                require(archive.testzip() is None, 'embedding jar CRC mismatch')
        else:
            require(record.get('host_os') == 'linux' and record.get('host_arch') == 'x64',
                    'unsupported gen_snapshot host')
            with path.open('rb') as stream:
                elf_machine(stream.read(20), 62, record['name'])
    verify = manifest.get('verify')
    require(isinstance(verify, dict), 'missing verify result')
    require(verify.get('snapshot') in ('pending', 'passed'), 'invalid snapshot result')
    require(verify.get('device') in ('pending', 'passed', 'skipped'), 'invalid device result')
    if verify['device'] == 'skipped':
        require(verify.get('device_reason') == 'no_android_device', 'invalid device skip reason')
    else:
        require(verify.get('device_reason') is None, 'unexpected device reason')
    if 'supersedes' in manifest:
        require(re.fullmatch(r'engine-' + re.escape(manifest['flutter_version']) + r'(?:-r[2-9][0-9]*|-r1[0-9]+)?',
                            manifest['supersedes']), 'invalid supersedes')
    if publishable:
        require(verify['snapshot'] == 'passed', 'snapshot verification not passed')
        require(verify['device'] in ('passed', 'skipped'), 'device verification pending')
        log = directory / 'build.log.zst'
        require(log.is_file() and log.stat().st_size > 0, 'missing compressed build log')
    return manifest


def package(build_dir, identity_path, directory):
    build_dir, directory = Path(build_dir), Path(directory)
    identity = read_json(identity_path)
    require(identity.get('build_completed') is True, 'build has not completed')
    require(not directory.exists() or not any(directory.iterdir()), 'output directory is not empty')
    directory.mkdir(parents=True, exist_ok=True)
    engine = build_dir / 'lib.stripped/libflutter.so'
    embedding = build_dir / 'flutter_embedding_release.jar'
    snapshot = build_dir / 'clang_x64/gen_snapshot'
    sources = {'engine': engine, 'embedding': embedding, 'gen_snapshot': snapshot}
    require(identity.get('output_sha256') == {key: sha256(path) for key, path in sources.items()},
            'build outputs changed since successful build')
    manifest = {key: identity[key] for key in (
        'flutter_version', 'engine_commit', 'engine_stamp', 'build_id', 'built_at',
        'builder_repo_commit', 'depot_tools_rev', 'patches')}
    manifest.update(schema=1, files=[], verify={
        'snapshot': 'pending', 'device': 'pending', 'device_reason': None})
    engine_jar = directory / 'libflutter-arm64_v8a-release.jar'
    member = 'lib/arm64-v8a/libflutter.so'
    info = zipfile.ZipInfo(member, (1980, 1, 1, 0, 0, 0))
    info.external_attr = 0o100755 << 16
    info.compress_type = zipfile.ZIP_STORED
    with zipfile.ZipFile(engine_jar, 'w') as archive:
        archive.writestr(info, engine.read_bytes())
    shutil.copyfile(embedding, directory / 'flutter_embedding_release.jar')
    shutil.copyfile(snapshot, directory / 'gen_snapshot-linux-x64')
    (directory / 'gen_snapshot-linux-x64').chmod(0o755)
    for role, name in (
        ('engine', engine_jar.name), ('embedding', 'flutter_embedding_release.jar'),
        ('gen_snapshot', 'gen_snapshot-linux-x64')):
        path = directory / name
        record = {'role': role, 'name': name, 'size': path.stat().st_size, 'sha256': sha256(path)}
        if role == 'engine':
            record.update(abi='arm64-v8a',
                          maven=f'io.flutter:arm64_v8a_release:1.0.0-{manifest["engine_stamp"]}',
                          contents=[{'name': member, 'sha256': sha256(engine), 'size': engine.stat().st_size}])
        elif role == 'embedding':
            record['maven'] = f'io.flutter:flutter_embedding_release:1.0.0-{manifest["engine_stamp"]}'
        else:
            record.update(host_os='linux', host_arch='x64')
        manifest['files'].append(record)
    write_json(directory / 'engine.manifest.json', manifest)
    validate(directory)
    return manifest


def comparable(manifest):
    result = copy.deepcopy(manifest)
    for key in ('build_id', 'built_at'):
        result.pop(key)
    for record in result['files']:
        record.pop('sha256')
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
    args = parser.parse_args()
    try:
        if args.command == 'package':
            package(args.build_dir, args.identity, args.out)
        elif args.command == 'validate':
            validate(args.directory, args.publishable)
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
