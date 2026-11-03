import hashlib
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import index
from artifacts import InvalidArtifact


def release(tag, build_id, extra_asset=False, draft=False, file_digest='e' * 64):
    manifest = {'flutter_version': '3.47.2', 'build_id': build_id, 'engine_api': 1,
                'capabilities': ['asset_overlay'],
                'files': [{'name': 'gen_snapshot-linux-x64', 'size': 3, 'sha256': 'e' * 64}]}
    data = json.dumps(manifest).encode()
    assets = [{'name': 'engine.manifest.json', 'browser_download_url': tag,
               'digest': 'sha256:' + hashlib.sha256(data).hexdigest()},
              {'name': 'gen_snapshot-linux-x64', 'size': 3, 'digest': 'sha256:' + file_digest}]
    if extra_asset:
        assets.append({'name': 'build.log', 'size': 1, 'digest': 'sha256:' + 'f' * 64})
    return {'tag_name': tag, 'draft': draft, 'assets': assets}, data


class Releases:
    def __init__(self, *releases):
        self.releases = {row[0]['tag_name']: row for row in releases}

    def request(self, method, path, missing_ok=False):
        found = self.releases.get(path.rsplit('/', 1)[1])
        return found[0] if found else None

    def fetch(self, url):
        return self.releases[url][1]


FIRST = ('engine-3.47.2-63b8646d', '63b8646d-e244-413e-a773-3455aeeef4b2')
SECOND = ('engine-3.47.2-0b85cdaf', '0b85cdaf-451e-424a-a982-37d3f78585e8')


class IndexTests(unittest.TestCase):
    def add(self, value, github, tag):
        index.add(github, value, tag, fetch=github.fetch)

    def test_the_release_added_last_is_current_and_earlier_ones_stay(self):
        github = Releases(release(*FIRST), release(*SECOND))
        value = {'schema': 1, 'flutter': {}}
        self.add(value, github, FIRST[0])
        self.add(value, github, SECOND[0])
        entry = value['flutter']['3.47.2']
        self.assertEqual(entry['current'], {'engine': SECOND[0]})
        self.assertEqual(sorted(entry['releases']), sorted([FIRST[0], SECOND[0]]))
        with self.assertRaisesRegex(InvalidArtifact, 'already listed'):
            self.add(value, github, FIRST[0])

    def test_only_a_published_release_matching_its_manifest_is_listed(self):
        for bad in (release(*FIRST, draft=True), release(*FIRST, extra_asset=True),
                    release(*FIRST, file_digest='0' * 64), release(FIRST[0], SECOND[1])):
            with self.subTest(bad=bad[0]['assets'][-1]['name']):
                value = {'schema': 1, 'flutter': {}}
                with self.assertRaises(InvalidArtifact):
                    self.add(value, Releases(bad), FIRST[0])
                self.assertEqual(value['flutter']['3.47.2']['releases'], {})
        with self.assertRaisesRegex(InvalidArtifact, 'invalid release tag'):
            self.add({'schema': 1, 'flutter': {}}, Releases(), 'flutter-3.47.2')


if __name__ == '__main__':
    unittest.main()