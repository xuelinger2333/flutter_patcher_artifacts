"""Strict tools manifest validation, hashing and A11 comparison (stdlib only)."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def names(version):
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid Flutter version')
    return {
        'tools': f'flutter_patcher_tools-{version}.dill',
    }


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f'Duplicate JSON field: {key}')
        result[key] = value
    return result


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=unique_object)


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def validate(directory):
    directory = Path(directory)
    manifest = read_json(directory / 'tools.manifest.json')
    require(type(manifest.get('schema')) is int and manifest['schema'] == 1, 'Unsupported tools schema')
    version = manifest.get('flutter_version')
    require(isinstance(version, str), 'Missing Flutter version')
    expected = names(version)
    require(isinstance(manifest.get('dart_version'), str) and
            re.fullmatch(r'\d+\.\d+\.\d+', manifest['dart_version']), 'Invalid Dart version')
    for field in ('engine_commit', 'builder_repo_commit', 'dart_sdk_commit'):
        require(isinstance(manifest.get(field), str) and
                re.fullmatch(r'[0-9a-f]{40}', manifest[field]), f'Invalid {field}')
    files = manifest.get('files')
    require(isinstance(files, list) and len(files) == 1, 'Exactly one tools snapshot is required')
    seen = set()
    for item in files:
        require(isinstance(item, dict), 'Invalid artifact entry')
        role = item.get('role')
        require(isinstance(role, str) and role in expected and role not in seen, 'Invalid or duplicate role')
        seen.add(role)
        require(item.get('name') == expected[role], 'Artifact filename mismatch')
        file = directory / item['name']
        require(file.is_file() and not file.is_symlink(), f'Missing artifact: {file.name}')
        require(type(item.get('size')) is int and item['size'] > 0, 'Invalid artifact size')
        require(file.stat().st_size == item['size'], f'Size mismatch: {file.name}')
        require(isinstance(item.get('sha256'), str) and re.fullmatch(r'[0-9a-f]{64}', item['sha256']), 'Invalid hash')
        require(sha256(file) == item['sha256'], f'Hash mismatch: {file.name}')
        if role == 'tools':
            with file.open('rb') as stream:
                require(stream.read(4) == b'\x90\xab\xcd\xef', f'Not a kernel snapshot: {file.name}')
    return manifest


def compare(first, second):
    left, right = validate(first), validate(second)
    require(left == right, 'A11 failed: tools manifests or artifact hashes differ')
    return left


def create(directory, version, metadata, repo_commit, dart_commit, patches):
    directory = Path(directory)
    manifest = {
        'schema': 1, 'flutter_version': version, 'dart_version': metadata['dartSdkVersion'].split()[0],
        'engine_commit': metadata['engineRevision'], 'builder_repo_commit': repo_commit,
        'dart_sdk_commit': dart_commit, 'patches': patches,
        'files': [{'name': name, 'role': role, 'sha256': sha256(directory / name),
                   'size': (directory / name).stat().st_size} for role, name in names(version).items()],
    }
    write_json(directory / 'tools.manifest.json', manifest)
    return validate(directory)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate', 'compare'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('second', nargs='?', type=Path)
    args = parser.parse_args()
    if args.command == 'compare':
        require(args.second is not None, 'Second directory required')
        compare(args.directory, args.second)
    else:
        validate(args.directory)
    print('OK')
