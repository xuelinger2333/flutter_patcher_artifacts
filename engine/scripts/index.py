#!/usr/bin/env python3
"""index.json lists the published releases; it is all the CLI reads to choose
artifacts.

`index.py add <tag>...` lists published (not draft) releases. Each release's
assets must be exactly the files its manifest names, with the manifest's
sizes and digests. Entries are never changed or removed; the release added
last becomes `current` for its kind and Flutter version, which new hosts use.
Hosts already built keep using the releases their baselines record.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen

from artifacts import InvalidArtifact, read_json, require, write_json
from github_release import KINDS, GitHub, release_tag

INDEX = Path(__file__).resolve().parents[2] / 'index.json'
TAG = re.compile(r'(engine|engine-ios|tools)-(\d+\.\d+\.\d+)-[0-9a-f]{8}')


def download(url):
    with urlopen(Request(url, headers={'User-Agent': 'flutter-patcher-index'}), timeout=180) as response:
        return response.read(1024 * 1024 + 1)


def add(github, index, tag, fetch=download):
    match = TAG.fullmatch(tag)
    require(match, f'invalid release tag: {tag}')
    kind, version = match.groups()
    entry = index['flutter'].setdefault(version, {'current': {}, 'releases': {}})
    require(tag not in entry['releases'], f'{tag} is already listed')
    release = github.request('GET', f'releases/tags/{tag}', missing_ok=True)
    require(release is not None and not release.get('draft'), f'{tag} is not a published release')
    assets = {asset['name']: asset for asset in release.get('assets', [])}
    manifest_name = KINDS[kind][1]
    require(manifest_name in assets, f'{tag} has no {manifest_name}')
    data = fetch(assets[manifest_name]['browser_download_url'])
    require(len(data) <= 1024 * 1024, f'{manifest_name} too large')
    digest = hashlib.sha256(data).hexdigest()
    require(assets[manifest_name].get('digest') == 'sha256:' + digest, f'{manifest_name} digest mismatch')
    manifest = json.loads(data)
    require(manifest.get('flutter_version') == version and release_tag(kind, manifest) == tag,
            f'{tag} does not name its manifest')
    files = {record['name']: record for record in manifest['files']}
    require(set(assets) == set(files) | {manifest_name}, f'{tag}: assets differ from the manifest')
    for name, record in files.items():
        require(assets[name].get('size') == record['size']
                and assets[name].get('digest') == 'sha256:' + record['sha256'], f'{tag}: {name} differs')
    if kind != 'tools':
        require(type(manifest.get('engine_api')) is int and isinstance(manifest.get('capabilities'), list),
                f'{tag}: engine manifest has no engine_api/capabilities')
    entry['releases'][tag] = {'kind': kind, 'manifest_sha256': digest}
    entry['current'][kind] = tag


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY'))
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('add').add_argument('tags', nargs='+')
    args = parser.parse_args()
    try:
        github = GitHub(args.repository or '', os.environ.get('GITHUB_TOKEN'))
        index = read_json(INDEX) if INDEX.exists() else {'schema': 1, 'flutter': {}}
        require(index.get('schema') == 1, 'unsupported index schema')
        for tag in args.tags:
            add(github, index, tag)
        write_json(INDEX, index)
    except (InvalidArtifact, OSError, ValueError, KeyError, TypeError) as error:
        print(f'INDEX_FAILED: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())