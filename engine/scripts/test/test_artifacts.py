import copy
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'artifacts.py'
SPEC = importlib.util.spec_from_file_location('artifacts', SCRIPT)
artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifacts)


def elf(machine):
    result = bytearray(64)
    result[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', result, 18, machine)
    return result


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / 'build'
        (self.build / 'lib.stripped').mkdir(parents=True)
        (self.build / 'clang_x64').mkdir()
        (self.build / 'lib.stripped/libflutter.so').write_bytes(elf(183))
        (self.build / 'clang_x64/gen_snapshot').write_bytes(elf(62))
        with zipfile.ZipFile(self.build / 'flutter_embedding_release.jar', 'w') as archive:
            archive.writestr('io/flutter/embedding/engine/FlutterJNI.class', b'fixture')
        self.identity = {
            'flutter_version': '3.47.2', 'engine_commit': 'a' * 40,
            'engine_stamp': 'b' * 40, 'builder_repo_commit': 'c' * 40,
            'depot_tools_rev': 'd' * 40, 'build_id': str(uuid.uuid4()),
            'built_at': '2026-09-07T00:00:00Z', 'build_completed': True,
            'patches': [{'file': '0001-fix.patch', 'sha256': 'e' * 64}],
            'output_sha256': {
                role: artifacts.sha256(self.build / file) for role, file in (
                    ('engine', 'lib.stripped/libflutter.so'),
                    ('embedding', 'flutter_embedding_release.jar'),
                    ('gen_snapshot', 'clang_x64/gen_snapshot'))},
        }
        self.identity_path = self.root / 'identity.json'
        artifacts.write_json(self.identity_path, self.identity)
        self.out = self.root / 'release'
        self.manifest = artifacts.package(self.build, self.identity_path, self.out)

    def write(self, value):
        artifacts.write_json(self.out / 'engine.manifest.json', value)

    def reject(self, mutate):
        value = copy.deepcopy(self.manifest)
        mutate(value)
        self.write(value)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            artifacts.validate(self.out)

    def test_engine_entry_and_embedding_round_trip(self):
        actual = artifacts.validate(self.out)
        with zipfile.ZipFile(self.out / actual['files'][0]['name']) as archive:
            self.assertEqual(archive.read('lib/arm64-v8a/libflutter.so'), elf(183))
        self.assertEqual((self.out / 'flutter_embedding_release.jar').read_bytes(),
                         (self.build / 'flutter_embedding_release.jar').read_bytes())

    def test_schema_unknown_and_boolean_rejected(self):
        for schema in (2, True, '1'):
            with self.subTest(schema=schema):
                self.reject(lambda m: m.update(schema=schema))

    def test_missing_required_fields(self):
        for key in ('flutter_version', 'engine_commit', 'engine_stamp', 'build_id',
                    'built_at', 'builder_repo_commit', 'depot_tools_rev', 'patches',
                    'files', 'verify'):
            with self.subTest(key=key):
                self.reject(lambda m: m.pop(key))

    def test_duplicate_roles(self):
        self.reject(lambda m: m['files'].__setitem__(1, m['files'][0]))

    def test_path_traversal(self):
        self.reject(lambda m: m['files'][0].update(name='../libflutter.so'))

    def test_invalid_commit(self):
        self.reject(lambda m: m.update(engine_commit='main'))

    def test_malformed_uuid_and_calendar_date_rejected(self):
        self.reject(lambda m: m.update(build_id=123))
        self.reject(lambda m: m.update(built_at='2026-99-99T00:00:00Z'))

    def test_invalid_host_and_abi(self):
        self.reject(lambda m: m['files'][0].update(abi='x86_64'))
        self.reject(lambda m: m['files'][2].update(host_os='windows'))

    def test_bad_maven_coordinate(self):
        self.reject(lambda m: m['files'][0].update(maven='io.flutter:arm64_v8a_release:wrong'))

    def test_inner_so_hash_checked_separately(self):
        self.reject(lambda m: m['files'][0]['contents'][0].update(sha256='f' * 64))

    def test_wrong_elf_architecture_even_with_valid_file_hash(self):
        path = self.out / 'gen_snapshot-linux-x64'
        path.write_bytes(elf(183))
        self.reject(lambda m: m['files'][2].update(sha256=artifacts.sha256(path)))

    def test_corrupted_bytes(self):
        path = self.out / 'gen_snapshot-linux-x64'
        path.write_bytes(bytes(64))
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            artifacts.validate(self.out)

    def test_missing_artifact(self):
        (self.out / 'gen_snapshot-linux-x64').unlink()
        with self.assertRaisesRegex(ValueError, 'missing'):
            artifacts.validate(self.out)

    def test_duplicate_json_keys(self):
        (self.out / 'engine.manifest.json').write_text('{"schema":1,"schema":1}')
        with self.assertRaisesRegex(ValueError, 'duplicate JSON'):
            artifacts.validate(self.out)

    def test_nonobject_manifest_rejected(self):
        (self.out / 'engine.manifest.json').write_text('[]')
        with self.assertRaisesRegex(ValueError, 'JSON object'):
            artifacts.validate(self.out)

    def test_publish_requires_snapshot_verification_and_log(self):
        with self.assertRaisesRegex(ValueError, 'snapshot verification'):
            artifacts.validate(self.out, publishable=True)
        self.manifest['verify'] = {'snapshot': 'passed', 'device': 'skipped',
                                   'device_reason': 'no_android_device'}
        self.write(self.manifest)
        with self.assertRaisesRegex(ValueError, 'compressed build log'):
            artifacts.validate(self.out, publishable=True)
        (self.out / 'build.log.zst').write_bytes(b'fixture')
        artifacts.validate(self.out, publishable=True)

    def test_device_failure_cannot_be_marked_skip_without_reason(self):
        self.reject(lambda m: m.update(verify={
            'snapshot': 'passed', 'device': 'skipped', 'device_reason': 'test_failed'}))

    def test_unchanged_outputs_required_for_package(self):
        (self.build / 'lib.stripped/libflutter.so').write_bytes(elf(62))
        with self.assertRaisesRegex(ValueError, 'outputs changed'):
            artifacts.package(self.build, self.identity_path, self.root / 'other')

    def test_cannot_overwrite_release(self):
        with self.assertRaisesRegex(ValueError, 'not empty'):
            artifacts.package(self.build, self.identity_path, self.out)

    def test_manifest_comparison_exclusions_are_narrow(self):
        other = copy.deepcopy(self.manifest)
        other.update(build_id=str(uuid.uuid4()), built_at='2026-09-08T00:00:00Z')
        other['files'][0]['sha256'] = 'f' * 64
        other['files'][0]['contents'][0]['sha256'] = 'f' * 64
        self.assertEqual(artifacts.comparable(self.manifest), artifacts.comparable(other))
        other['files'][0]['size'] += 1
        self.assertNotEqual(artifacts.comparable(self.manifest), artifacts.comparable(other))

    def test_validation_error_exits_nonzero(self):
        (self.out / 'gen_snapshot-linux-x64').unlink()
        process = subprocess.run([sys.executable, str(SCRIPT), 'validate', str(self.out)],
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertIn('ENGINE_ARTIFACT_INVALID', process.stderr)


if __name__ == '__main__':
    unittest.main()
