from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import github_release


class FakeGitHub:
    def __init__(self, tags=(), issues=()):
        self.tags = set(tags)
        self.issues = list(issues)
        self.created = []

    def exists(self, tag):
        return tag in self.tags

    def request(self, method, path, body=None):
        if method == 'GET':
            return self.issues
        self.created.append((path, body))
        return {'html_url': 'https://github.com/example/engine/issues/1'}


class ReleaseTests(unittest.TestCase):
    def test_missing_release_never_created(self):
        github = FakeGitHub()
        with self.assertRaisesRegex(ValueError, 'manually'):
            github_release.existing_release(github, '3.47.2')
        self.assertEqual(github.created, [])

    def test_existing_draft_found(self):
        github = FakeGitHub(issues=[{'id': 7, 'tag_name': 'flutter-3.47.2', 'draft': True}])
        self.assertEqual(github_release.existing_release(github, '3.47.2')['id'], 7)
        self.assertEqual(github.created, [])

    def test_uploads_only_engine_files_and_manifest(self):
        from unittest.mock import patch
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            filenames = ['libflutter-arm64_v8a-release.jar', 'gen_snapshot-linux-x64',
                         'flutter_embedding_release.jar', 'engine.manifest.json']
            for name in filenames:
                (root / name).write_bytes(b'fixture')
            calls = []
            class API:
                def request(self, method, path, body=None, upload=None):
                    calls.append((method, path))
                    if method == 'GET':
                        return [{'id': 7, 'tag_name': 'flutter-3.47.2', 'draft': True,
                                 'assets': [{'name': 'tools.manifest.json'}], 'html_url': 'review'}]
                    if upload is None:
                        raise AssertionError('Release/tag mutation attempted')
                    data = Path(upload).read_bytes()
                    return {'state': 'uploaded', 'size': len(data), 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}
            manifest = {'flutter_version': '3.47.2', 'files': [{'name': n} for n in filenames[:-1]]}
            with patch.object(github_release, 'validate', return_value=manifest):
                github_release.publish(API(), root)
            self.assertEqual(sum(method == 'POST' for method, _ in calls), 4)
            self.assertTrue(all(method == 'GET' or '/assets?' in path for method, path in calls))

    def test_select_stable_by_revision_not_list_order(self):
        document = {'current_release': {'stable': 'a'}, 'releases': [
            {'hash': 'b', 'version': '9.0.0', 'channel': 'beta'},
            {'hash': 'a', 'version': '3.47.2', 'channel': 'stable'}]}
        self.assertEqual(github_release.newest_stable(document), '3.47.2')

    def test_missing_current_stable_fails(self):
        with self.assertRaises(ValueError):
            github_release.newest_stable({'current_release': {'stable': 'missing'}, 'releases': []})

    def test_stable_check_is_idempotent_and_never_builds(self):
        document = {'current_release': {'stable': 'a'}, 'releases': [
            {'hash': 'a', 'version': '3.47.2', 'channel': 'stable'}]}
        with tempfile.TemporaryDirectory() as directory:
            supported = Path(directory) / 'versions.txt'
            supported.write_text('3.46.0\n')
            github = FakeGitHub()
            github_release.check_stable(github, supported, document)
            self.assertEqual(len(github.created), 1)
            self.assertEqual(github.created[0][0], 'issues')
            github.issues.append(github.created[0][1])
            github_release.check_stable(github, supported, document)
            self.assertEqual(len(github.created), 1)
            supported.write_text('3.47.2\n')
            github_release.check_stable(github, supported, document)
            self.assertEqual(len(github.created), 1)

    def test_closed_issue_still_suppresses_duplicate(self):
        document = {'current_release': {'stable': 'a'}, 'releases': [
            {'hash': 'a', 'version': '3.47.2', 'channel': 'stable'}]}
        with tempfile.TemporaryDirectory() as directory:
            supported = Path(directory) / 'versions.txt'
            supported.write_text('')
            github = FakeGitHub(issues=[{
                'state': 'closed', 'body': '<!-- flutter-patcher-engine-stable:3.47.2 -->'}])
            github_release.check_stable(github, supported, document)
            self.assertEqual(github.created, [])


if __name__ == '__main__':
    unittest.main()
