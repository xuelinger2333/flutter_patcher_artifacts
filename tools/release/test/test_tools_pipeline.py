import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools_artifacts import create, validate, compare, names, write_json
from publish_tools import existing_release, publish
from select_versions import select


class ArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.first = self.root / 'first'
        self.first.mkdir()
        self.version = '3.47.2'
        self.metadata = {'dartSdkVersion': '3.13.2 (stable)', 'engineRevision': 'a' * 40}
        for role, name in names(self.version).items():
            data = b'\x90\xab\xcd\xefexample' if role == 'tools' else b'callable: []\n'
            (self.first / name).write_bytes(data)
        self.manifest = create(self.first, self.version, self.metadata, 'b' * 40, 'c' * 40, [])

    def change(self, update):
        manifest = copy.deepcopy(self.manifest)
        update(manifest)
        write_json(self.first / 'tools.manifest.json', manifest)
        with self.assertRaises(ValueError):
            validate(self.first)

    def test_valid(self):
        self.assertEqual(validate(self.first), self.manifest)

    def test_corrupt_artifact(self):
        (self.first / names(self.version)['tools']).write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            validate(self.first)

    def test_missing_role(self):
        self.change(lambda m: m['files'].pop())

    def test_duplicate_role(self):
        self.change(lambda m: m['files'].append(m['files'][0]))

    def test_path_traversal(self):
        self.change(lambda m: m['files'][0].update(name='../snapshot.dill'))

    def test_unknown_schema(self):
        self.change(lambda m: m.update(schema=2))

    def test_bool_schema(self):
        self.change(lambda m: m.update(schema=True))

    def test_missing_engine(self):
        self.change(lambda m: m.pop('engine_commit'))

    def test_bad_hash(self):
        self.change(lambda m: m['files'][0].update(sha256='f' * 64))

    def test_bool_size(self):
        self.change(lambda m: m['files'][0].update(size=True))

    def test_duplicate_json_field(self):
        path = self.first / 'tools.manifest.json'
        path.write_text('{"schema":1,' + path.read_text()[1:])
        with self.assertRaises(ValueError):
            validate(self.first)

    def test_repeatability_requires_identical_bytes(self):
        import shutil
        second = self.root / 'second'
        shutil.copytree(self.first, second)
        compare(self.first, second)
        (second / names(self.version)['tools']).write_bytes(b'\x90\xab\xcd\xefchanged')
        create(second, self.version, self.metadata, 'b' * 40, 'c' * 40, [])
        with self.assertRaises(ValueError):
            compare(self.first, second)

    def test_mislabeled_snapshot(self):
        (self.first / names(self.version)['tools']).write_bytes(b'not kernel')
        with self.assertRaises(ValueError):
            create(self.first, self.version, self.metadata, 'b' * 40, 'c' * 40, [])

    def test_uploads_only_tools_assets_to_existing_draft(self):
        calls = []
        class API:
            def request(self, method, path, body=None, binary=False):
                calls.append((method, path))
                if method == 'GET':
                    return [{'id': 1, 'tag_name': 'flutter-3.47.2', 'draft': True,
                             'assets': [{'name': 'engine.manifest.json'}],
                             'upload_url': 'https://uploads.github.com/assets{?name}', 'html_url': 'review'}]
                if binary:
                    import hashlib
                    from urllib.parse import parse_qs, urlparse
                    name = parse_qs(urlparse(path).query)['name'][0]
                    return {'name': name, 'size': len(body), 'digest': 'sha256:' + hashlib.sha256(body).hexdigest()}
                raise AssertionError('Attempted release/tag mutation')
        publish(self.first, API())
        self.assertEqual(sum('uploads.github.com' in path for _, path in calls), 2)
        self.assertFalse(any(method in ('PATCH', 'DELETE') for method, _ in calls))

    def test_missing_release_fails_without_writes(self):
        class API:
            def request(self, method, path, body=None, binary=False):
                self_test.assertEqual(method, 'GET')
                return []
        self_test = self
        with self.assertRaisesRegex(ValueError, 'manually'):
            publish(self.first, API())

    def test_existing_asset_fails_before_any_upload(self):
        class API:
            def request(self, method, path, body=None, binary=False):
                self_test.assertEqual(method, 'GET')
                return [{'id': 1, 'tag_name': 'flutter-3.47.2',
                         'assets': [{'name': 'tools.manifest.json'}]}]
        self_test = self
        with self.assertRaisesRegex(ValueError, 'already exist'):
            publish(self.first, API())

    def test_bad_upload_digest_fails(self):
        class API:
            def request(self, method, path, body=None, binary=False):
                if method == 'GET':
                    return [{'id': 1, 'tag_name': 'flutter-3.47.2', 'assets': [],
                             'upload_url': 'https://uploads.github.com/assets{?name}'}]
                self_test.assertTrue(binary)
                return {'name': names('3.47.2')['tools'], 'size': len(body), 'digest': 'sha256:' + '0' * 64}
        self_test = self
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            publish(self.first, API())


class SelectionTest(unittest.TestCase):
    def test_compiler_help_uses_boolean_flag_notation(self):
        from build_tools import check_compiler_help
        check_compiler_help('--[no-]tfa  TFA\n--[no-]aot-only  AOT')
        with self.assertRaises(ValueError):
            check_compiler_help('--[no-]aot-only  AOT')

    def test_machine_output_excludes_stderr(self):
        from build_tools import run
        result = run(sys.executable, '-c', 'import sys; print("warning", file=sys.stderr); print("{}")', capture=True)
        self.assertEqual(json.loads(result), {})

    def test_all(self):
        self.assertEqual(select('all', ['3.47.2'], {'3.47.2': {}}), ['3.47.2'])

    def test_support_drift(self):
        with self.assertRaises(ValueError):
            select('all', ['3.47.2'], {'3.47.1': {}})

    def test_untrusted_version_input(self):
        with self.assertRaises(ValueError):
            select('$(id)', ['3.47.2'], {'3.47.2': {}})

    def test_existing_draft_found_on_second_page(self):
        class API:
            def request(self, method, path):
                if path.endswith('page=1'):
                    return [{'tag_name': f'other-{i}'} for i in range(100)]
                return [{'id': 9, 'tag_name': 'flutter-3.47.2', 'draft': True}]
        self.assertEqual(existing_release(API(), '3.47.2')['id'], 9)


if __name__ == '__main__':
    unittest.main()
