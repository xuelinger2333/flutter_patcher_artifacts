"""Upload one verified snapshot and its manifest to an existing Flutter release."""
import argparse
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

from tools_artifacts import names, require, sha256, validate, write_json


class GitHub:
    def __init__(self, repo, token):
        require(re.fullmatch(r'[\w.-]+/[\w.-]+', repo), 'Invalid GitHub repository')
        self.repo, self.token = repo, token

    def request(self, method, path, body=None, binary=False):
        url = path if path.startswith('https://uploads.github.com/') else f'https://api.github.com/repos/{self.repo}{path}'
        headers = {'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'flutter-patcher-tools-builder'}
        if body is not None:
            headers['Content-Type'] = 'application/octet-stream' if binary else 'application/json'
            if not binary:
                body = json.dumps(body).encode()
        request = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if method == 'GET' and error.code == 404:
                return None
            raise RuntimeError(f'GitHub {method} failed with HTTP {error.code}') from None


def existing_release(api, version):
    tag = f'flutter-{version}'
    page = 1
    while True:
        releases = api.request('GET', f'/releases?per_page=100&page={page}')
        matches = [release for release in releases if release.get('tag_name') == tag]
        require(len(matches) <= 1, f'Ambiguous release: {tag}')
        if matches:
            return matches[0]
        if len(releases) < 100:
            raise ValueError(f'Release {tag} does not exist; ask the user to create it manually first')
        page += 1


def publish(directory, api):
    directory = Path(directory)
    manifest = validate(directory)
    release = existing_release(api, manifest['flutter_version'])
    filenames = [*names(manifest['flutter_version']).values(), 'tools.manifest.json']
    existing = {asset['name'] for asset in release.get('assets', [])}
    require(not existing.intersection(filenames), 'Tools assets already exist; user review is required before replacement')
    for filename in filenames:
        path = directory / filename
        url = release['upload_url'].split('{', 1)[0] + '?name=' + urllib.parse.quote(filename)
        asset = api.request('POST', url, path.read_bytes(), binary=True)
        require(asset['name'] == filename and asset['size'] == path.stat().st_size, 'Uploaded asset size/name mismatch')
        require(asset.get('digest') == 'sha256:' + sha256(path), 'Uploaded asset hash mismatch')
    print(release['html_url'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    publish(args.directory.resolve(), GitHub(os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_TOKEN']))
