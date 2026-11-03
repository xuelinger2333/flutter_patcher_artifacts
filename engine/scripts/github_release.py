#!/usr/bin/env python3
"""Publish immutable artifact releases or report newly unsupported stable versions.

Every build is published once, under its own tag, as a draft for the
maintainer to review and publish; index.py then lists it. A release is never
changed afterwards: hosts built with it keep patching against it.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

from artifacts import InvalidArtifact, read_json, require, validate, validate_ios, write_json

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools' / 'release'))
import tools_artifacts  # noqa: E402


class GitHub:
    def __init__(self, repository, token):
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository),
                'invalid GitHub repository')
        self.repository = repository
        self.token = token  # reads of published releases need none

    def request(self, method, path, body=None, missing_ok=False, upload=None):
        root = 'https://uploads.github.com' if upload is not None else 'https://api.github.com'
        url = f'{root}/repos/{self.repository}/{path}'
        headers = {'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'flutter-patcher-engine'}
        if self.token:
            headers['Authorization'] = f'Bearer {self.token}'
        data = None
        if upload is not None:
            data = Path(upload).read_bytes()
            headers['Content-Type'] = 'application/octet-stream'
        elif body is not None:
            data = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        try:
            with urlopen(Request(url, data=data, headers=headers, method=method), timeout=180) as response:
                return json.load(response)
        except HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise InvalidArtifact(f'GitHub {method} {path.split("?")[0]}: HTTP {error.code}') from error

    def exists(self, tag):
        encoded = quote(tag, safe='')
        release = self.request('GET', f'releases/tags/{encoded}', missing_ok=True)
        ref = self.request('GET', f'git/ref/tags/{encoded}', missing_ok=True)
        return release is not None or ref is not None


def verified_ios(directory):
    """An iOS engine built on a Mac; the CLI accepts it only once verified."""
    manifest = validate_ios(directory)
    require(manifest['verify']['snapshot'] == 'passed' and manifest['verify']['device'] != 'pending',
            'iOS engine verification did not pass')
    return manifest


# Release kind: validation of a publishable directory, and its manifest file.
KINDS = {
    'engine': (lambda directory: validate(directory, publishable=True), 'engine.manifest.json'),
    'engine-ios': (verified_ios, 'engine-ios.manifest.json'),
    'tools': (tools_artifacts.validate, 'tools.manifest.json'),
}


def release_tag(kind, manifest):
    """`<kind>-<flutter>-<id>`: an engine's build_id, or the reproducible tools
    snapshot's digest, so one build always maps to one tag."""
    identity = manifest['files'][0]['sha256'] if kind == 'tools' else manifest['build_id'].replace('-', '')
    return f'{kind}-{manifest["flutter_version"]}-{identity[:8]}'


def find_release(github, tag):
    """The release (draft or published) or tag named `tag`, if any."""
    page = 1
    while True:
        releases = github.request('GET', f'releases?per_page=100&page={page}')
        if any(release.get('tag_name') == tag for release in releases):
            return True
        if len(releases) < 100:
            return github.exists(tag)
        page += 1


def publish(github, kind, directory):
    require(bool(github.token), 'GITHUB_TOKEN is required')
    check, manifest_name = KINDS[kind]
    directory = Path(directory)
    manifest = check(directory)
    tag = release_tag(kind, manifest)
    require(not find_release(github, tag), f'{tag} already exists; a release is never changed')
    release = github.request('POST', 'releases', {
        'tag_name': tag, 'target_commitish': manifest['builder_repo_commit'], 'name': tag, 'draft': True,
        'body': f'Flutter {manifest["flutter_version"]} {kind}, built from {manifest["builder_repo_commit"]}. '
                'Review the assets, publish this draft, then list it with engine/scripts/index.py.'})
    names = [record['name'] for record in manifest['files']] + [manifest_name]
    for name in names:
        path = directory / name
        uploaded = github.request('POST', f'releases/{release["id"]}/assets?name={quote(name)}', upload=path)
        require(uploaded.get('state') == 'uploaded' and uploaded.get('size') == path.stat().st_size,
                f'upload incomplete: {name}')
        expected = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        require(uploaded.get('digest') == expected, f'uploaded SHA-256 mismatch: {name}')
    print(release['html_url'])


def newest_stable(document):
    revision = document['current_release']['stable']
    candidates = [entry for entry in document['releases']
                  if entry.get('hash') == revision and entry.get('channel') == 'stable']
    require(len(candidates) == 1, 'stable release lookup is ambiguous or missing')
    version = candidates[0]['version']
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'invalid stable version')
    return version


def check_stable(github, supported_path, release_document):
    version = newest_stable(release_document)
    supported = Path(supported_path).read_text().splitlines()
    if version in supported:
        print(f'Flutter {version} is already supported')
        return
    marker = f'<!-- flutter-patcher-engine-stable:{version} -->'
    page = 1
    while True:
        issues = github.request('GET', f'issues?state=all&per_page=100&page={page}')
        if any(marker in (issue.get('body') or '') for issue in issues):
            print(f'Flutter {version} already has a tracking issue')
            return
        if len(issues) < 100:
            break
        page += 1
    issue = github.request('POST', 'issues', {
        'title': f'Validate Flutter {version} engine support',
        'body': f'{marker}\nFlutter {version} is the current stable release and is not in '
                'supported_versions.txt.\n\nValidate the pinned source, patch applicability, '
                'build targets and engine/snapshot pairing before adding support. '
                'This issue does not trigger an engine build.'})
    print(issue['html_url'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY'))
    commands = parser.add_subparsers(dest='command', required=True)
    release = commands.add_parser('publish')
    release.add_argument('kind', choices=sorted(KINDS))
    release.add_argument('directory')
    stable = commands.add_parser('check-stable')
    stable.add_argument('--supported', default='supported_versions.txt')
    stable.add_argument('--releases-json')
    args = parser.parse_args()
    try:
        github = GitHub(args.repository or '', os.environ.get('GITHUB_TOKEN'))
        if args.command == 'publish':
            publish(github, args.kind, args.directory)
        else:
            if args.releases_json:
                document = read_json(args.releases_json)
            else:
                with urlopen('https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json',
                             timeout=60) as response:
                    document = json.load(response)
            check_stable(github, args.supported, document)
    except (InvalidArtifact, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'RELEASE_FAILED: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
