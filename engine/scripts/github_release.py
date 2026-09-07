#!/usr/bin/env python3
"""Publish immutable engine releases or report newly unsupported stable versions."""

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

from artifacts import InvalidArtifact, read_json, require, validate, write_json


class GitHub:
    def __init__(self, repository, token):
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository),
                'invalid GitHub repository')
        require(bool(token), 'GITHUB_TOKEN is required')
        self.repository = repository
        self.token = token

    def request(self, method, path, body=None, missing_ok=False, upload=None):
        root = 'https://uploads.github.com' if upload is not None else 'https://api.github.com'
        url = f'{root}/repos/{self.repository}/{path}'
        headers = {'Authorization': f'Bearer {self.token}',
                   'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'flutter-patcher-engine'}
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


def existing_release(github, version):
    tag = f'flutter-{version}'
    page = 1
    while True:
        releases = github.request('GET', f'releases?per_page=100&page={page}')
        matches = [release for release in releases if release.get('tag_name') == tag]
        require(len(matches) <= 1, f'Ambiguous release: {tag}')
        if matches:
            return matches[0]
        if len(releases) < 100:
            raise InvalidArtifact(f'Release {tag} does not exist; ask the user to create it manually first')
        page += 1


def publish(github, directory):
    directory = Path(directory)
    manifest = validate(directory, publishable=True)
    release = existing_release(github, manifest['flutter_version'])
    names = [record['name'] for record in manifest['files']] + ['engine.manifest.json']
    existing = {asset['name'] for asset in release.get('assets', [])}
    require(not existing.intersection(names), 'Engine assets already exist; user review is required before replacement')
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
    release.add_argument('directory')
    stable = commands.add_parser('check-stable')
    stable.add_argument('--supported', default='supported_versions.txt')
    stable.add_argument('--releases-json')
    args = parser.parse_args()
    try:
        github = GitHub(args.repository or '', os.environ.get('GITHUB_TOKEN'))
        if args.command == 'publish':
            publish(github, args.directory)
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
