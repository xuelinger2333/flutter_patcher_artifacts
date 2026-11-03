import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools_artifacts import create, validate, compare, names, write_json
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

    def test_list(self):
        table = ['3.47.0', '3.47.1', '3.47.2']
        pins = dict.fromkeys(table, {})
        self.assertEqual(select('3.47.2, 3.47.0', table, pins), ['3.47.2', '3.47.0'])
        for requested in ('3.47.0,3.47.0', '3.47.0,3.47.3'):
            with self.assertRaises(ValueError):
                select(requested, table, pins)

    def test_support_drift(self):
        with self.assertRaises(ValueError):
            select('all', ['3.47.2'], {'3.47.1': {}})

    def test_untrusted_version_input(self):
        with self.assertRaises(ValueError):
            select('$(id)', ['3.47.2'], {'3.47.2': {}})

if __name__ == '__main__':
    unittest.main()
