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
    def publish(self, kind, manifest, releases=(), tags=()):
        """Publishes fixture files for `manifest`; returns the API calls."""
        from unittest.mock import patch
        import hashlib
        calls = []
        class API:
            token = 'test'

            def exists(self, tag):
                return tag in tags
            def request(self, method, path, body=None, upload=None):
                calls.append((method, path, body))
                if method == 'GET':
                    return list(releases)
                if upload is None:
                    return {'id': 7, 'html_url': 'review'}
                data = Path(upload).read_bytes()
                return {'state': 'uploaded', 'size': len(data), 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in [row['name'] for row in manifest['files']] + [github_release.KINDS[kind][1]]:
                (root / name).write_bytes(b'fixture')
            with patch.dict(github_release.KINDS, {kind: (lambda _: manifest, github_release.KINDS[kind][1])}):
                github_release.publish(API(), kind, root)
        return calls

    def test_each_build_becomes_one_new_draft_release(self):
        manifest = {'flutter_version': '3.47.2', 'build_id': '63b8646d-e244-413e-a773-3455aeeef4b2',
                    'builder_repo_commit': 'c' * 40,
                    'files': [{'name': n} for n in ('libflutter-arm64_v8a-release.jar', 'gen_snapshot-linux-x64')]}
        calls = self.publish('engine', manifest)
        created = [body for method, path, body in calls if path == 'releases']
        self.assertEqual(len(created), 1)
        self.assertEqual({k: created[0][k] for k in ('tag_name', 'target_commitish', 'draft')},
                         {'tag_name': 'engine-3.47.2-63b8646d', 'target_commitish': 'c' * 40, 'draft': True})
        uploads = [path for method, path, body in calls if '/assets?' in path]
        self.assertEqual([path.rsplit('=', 1)[1] for path in uploads],
                         ['libflutter-arm64_v8a-release.jar', 'gen_snapshot-linux-x64', 'engine.manifest.json'])

    def test_tools_are_tagged_by_their_reproducible_digest(self):
        manifest = {'flutter_version': '3.47.2', 'builder_repo_commit': 'c' * 40,
                    'files': [{'name': 'flutter_patcher_tools-3.47.2.dill', 'sha256': '6427c8dd' + '0' * 56}]}
        self.assertEqual(github_release.release_tag('tools', manifest), 'tools-3.47.2-6427c8dd')

    def test_an_existing_draft_or_tag_is_never_changed(self):
        manifest = {'flutter_version': '3.47.2', 'build_id': '63b8646d-e244-413e-a773-3455aeeef4b2',
                    'builder_repo_commit': 'c' * 40, 'files': [{'name': 'gen_snapshot-linux-x64'}]}
        for kwargs in ({'releases': [{'tag_name': 'engine-3.47.2-63b8646d', 'draft': True}]},
                       {'tags': {'engine-3.47.2-63b8646d'}}):
            with self.subTest(**{k: str(v) for k, v in kwargs.items()}):
                with self.assertRaisesRegex(github_release.InvalidArtifact, 'never changed'):
                    self.publish('engine', manifest, **kwargs)

    def test_an_upload_with_another_digest_fails(self):
        from unittest.mock import patch
        manifest = {'flutter_version': '3.47.2', 'build_id': '63b8646d-e244-413e-a773-3455aeeef4b2',
                    'builder_repo_commit': 'c' * 40, 'files': [{'name': 'gen_snapshot-linux-x64'}]}
        class API:
            token = 'test'

            def exists(self, tag):
                return False
            def request(self, method, path, body=None, upload=None):
                if method == 'GET':
                    return []
                if upload is None:
                    return {'id': 7}
                return {'state': 'uploaded', 'size': Path(upload).stat().st_size, 'digest': 'sha256:' + '0' * 64}
        with tempfile.TemporaryDirectory() as directory:
            for name in ('gen_snapshot-linux-x64', 'engine.manifest.json'):
                (Path(directory) / name).write_bytes(b'fixture')
            with patch.dict(github_release.KINDS, {'engine': (lambda _: manifest, 'engine.manifest.json')}):
                with self.assertRaisesRegex(github_release.InvalidArtifact, 'SHA-256 mismatch'):
                    github_release.publish(API(), 'engine', directory)

    def test_ios_requires_a_verified_engine(self):
        from unittest.mock import patch
        manifest = {'verify': {'snapshot': 'pending', 'device': 'pending'}}
        with patch.object(github_release, 'validate_ios', return_value=manifest):
            with self.assertRaises(github_release.InvalidArtifact):
                github_release.verified_ios(Path('.'))
            manifest['verify'] = {'snapshot': 'passed', 'device': 'skipped'}
            self.assertIs(github_release.verified_ios(Path('.')), manifest)
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
