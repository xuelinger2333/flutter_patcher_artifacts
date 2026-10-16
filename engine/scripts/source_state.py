#!/usr/bin/env python3
"""Audit managed DEPS checkouts and record successful build provenance."""
import argparse
import ast
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import uuid

from artifacts import require, sha256, read_json, write_json


def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], text=True).strip()


def patches(repo):
    paths = sorted((Path(repo) / 'engine_patches').glob('*.patch'))
    require(bool(paths), 'no engine patches')
    return [{'file': path.name, 'sha256': sha256(path)} for path in paths]


def check_clean(engine):
    engine = Path(engine).resolve()
    entries = engine / '.gclient_entries'
    paths = [engine]
    if entries.exists():
        tree = ast.parse(entries.read_text())
        require(len(tree.body) == 1 and isinstance(tree.body[0], ast.Assign), 'invalid gclient entries')
        mapping = ast.literal_eval(tree.body[0].value)
        for relative in mapping:
            path = (engine / relative).resolve()
            require(path == engine or engine in path.parents, 'DEPS checkout escapes managed root')
            if (path / '.git').exists():
                paths.append(path)
    for path in set(paths):
        require(not git(path, 'status', '--porcelain', '--untracked-files=no'),
                f'managed source has tracked edits: {path}')


def record_build(repo, engine, resolved, output):
    repo, engine = Path(repo), Path(engine)
    identity = read_json(resolved)
    require(not git(repo, 'status', '--porcelain'), 'dirty builder repository')
    require(git(engine, 'rev-parse', 'HEAD') == identity['engine_commit'], 'engine commit mismatch')
    out = engine / 'engine/src/out/android_release_arm64'
    identity.update(
        schema=1, builder_repo_commit=git(repo, 'rev-parse', 'HEAD'),
        depot_tools_rev=(repo / 'DEPOT_TOOLS_REV').read_text().strip(),
        build_id=str(uuid.uuid4()),
        built_at=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        patches=patches(repo), build_completed=True,
        output_sha256={role: sha256(out / path) for role, path in (
            ('engine', 'lib.stripped/libflutter.so'),
            ('embedding', 'flutter_embedding_release.jar'),
            ('gen_snapshot', 'clang_x64/gen_snapshot'))})
    write_json(output, identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check-clean')
    check.add_argument('engine')
    patch = commands.add_parser('patches')
    patch.add_argument('repo')
    record = commands.add_parser('record-build')
    record.add_argument('repo')
    record.add_argument('engine')
    record.add_argument('resolved')
    record.add_argument('output')
    args = parser.parse_args()
    try:
        if args.command == 'check-clean':
            check_clean(args.engine)
        elif args.command == 'patches':
            print(json.dumps(patches(args.repo), sort_keys=True))
        else:
            record_build(args.repo, args.engine, args.resolved, args.output)
    except (OSError, ValueError, SyntaxError, subprocess.CalledProcessError) as error:
        print(f'SOURCE_INVALID: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
