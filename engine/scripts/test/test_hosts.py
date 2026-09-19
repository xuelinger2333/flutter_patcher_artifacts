import copy
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import uuid
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import hosts
SPEC = importlib.util.spec_from_file_location('artifacts', SCRIPTS / 'artifacts.py')
artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifacts)


def elf(machine):
    result = bytearray(64)
    result[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', result, 18, machine)
    return bytes(result)


PE = b'MZ' + bytes(62)
MACHO = b'\xcf\xfa\xed\xfe' + bytes(60)


class HostTests(unittest.TestCase):
    def test_names_follow_the_sdk_toolchain_directory(self):
        self.assertEqual(hosts.gen_snapshot_name('linux-x64'), 'gen_snapshot-linux-x64')
        self.assertEqual(hosts.gen_snapshot_name('windows-x64'), 'gen_snapshot-windows-x64.exe')
        self.assertEqual(hosts.gen_snapshot_name('macos-arm64'), 'gen_snapshot-darwin-arm64')
        self.assertEqual(hosts.gen_snapshot_install('windows-x64'),
                         'bin/cache/artifacts/engine/android-arm64-release/windows-x64/gen_snapshot.exe')
        self.assertEqual(hosts.script('windows-x64', 'flutter'), 'flutter.bat')
        self.assertEqual(hosts.script('linux-x64', 'flutter'), 'flutter')

    def test_invalid_hosts_rejected(self):
        for host_os, host_arch in (('win', 'x64'), ('linux', 'x86_64'), (None, 'x64'), ('darwin', 'arm64')):
            with self.assertRaises(hosts.HostError):
                hosts.key(host_os, host_arch)
        self.assertIn(hosts.current(), hosts.SUPPORTED + ('linux-arm64', 'macos-x64', 'windows-arm64'))

    def test_native_executable_magic_per_host(self):
        self.assertTrue(hosts.is_native_executable('linux-x64', elf(62)))
        self.assertFalse(hosts.is_native_executable('linux-x64', elf(183)))
        self.assertTrue(hosts.is_native_executable('windows-x64', PE))
        self.assertFalse(hosts.is_native_executable('windows-x64', elf(62)))
        self.assertTrue(hosts.is_native_executable('macos-arm64', MACHO))
        self.assertFalse(hosts.is_native_executable('macos-arm64', b'MZ'))


class AttachTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = {
            'flutter_version': '3.47.2', 'engine_commit': 'a' * 40,
            'engine_stamp': 'b' * 40, 'builder_repo_commit': 'c' * 40,
            'depot_tools_rev': 'd' * 40, 'build_id': str(uuid.uuid4()),
            'built_at': '2026-09-07T00:00:00Z', 'build_completed': True,
            'patches': [{'file': '0001-fix.patch', 'sha256': 'e' * 64}],
        }
        build = self.root / 'build'
        (build / 'lib.stripped').mkdir(parents=True)
        (build / 'clang_x64').mkdir()
        (build / 'lib.stripped/libflutter.so').write_bytes(elf(183))
        (build / 'clang_x64/gen_snapshot').write_bytes(elf(62))
        with zipfile.ZipFile(build / 'flutter_embedding_release.jar', 'w') as archive:
            archive.writestr('io/flutter/embedding/engine/FlutterJNI.class', b'fixture')
        self.identity['output_sha256'] = {
            role: artifacts.sha256(build / file) for role, file in (
                ('engine', 'lib.stripped/libflutter.so'),
                ('embedding', 'flutter_embedding_release.jar'),
                ('gen_snapshot', 'clang_x64/gen_snapshot'))}
        artifacts.write_json(self.root / 'identity.json', self.identity)
        self.release = self.root / 'release'
        self.manifest = artifacts.package(build, self.root / 'identity.json', self.release)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        (self.bundle / 'gen_snapshot-windows-x64.exe').write_bytes(PE)
        self.host_manifest = {
            'schema': 1, 'kind': 'host_snapshot', 'host_os': 'windows', 'host_arch': 'x64',
            'built_at': '2026-09-19T00:00:00Z', 'verify': {'snapshot': 'passed'},
            'toolchain': {'visual_studio': '18'},
            'file': {'name': 'gen_snapshot-windows-x64.exe', 'size': len(PE),
                     'sha256': artifacts.sha256(self.bundle / 'gen_snapshot-windows-x64.exe')},
            **{key: self.identity[key] for key in (
                'flutter_version', 'engine_commit', 'engine_stamp', 'builder_repo_commit',
                'depot_tools_rev', 'patches')},
        }
        self.write_bundle(self.host_manifest)

    def write_bundle(self, value):
        artifacts.write_json(self.bundle / 'host.manifest.json', value)

    def downgrade_to_schema_1(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['schema'] = 1
        record = manifest['files'][2]
        for key in ('verify', 'built_at', 'builder_repo_commit'):
            record.pop(key)
        manifest['verify'] = {'snapshot': 'passed', 'device': 'passed', 'device_reason': None}
        artifacts.write_json(self.release / 'engine.manifest.json', manifest)
        return manifest

    def test_package_writes_schema_2_with_primary_record(self):
        self.assertEqual(self.manifest['schema'], 2)
        record = artifacts.snapshot_record(self.manifest, 'linux-x64')
        self.assertEqual(record['verify'], {'snapshot': 'pending', 'device': 'pending', 'device_reason': None})
        self.assertEqual(record['builder_repo_commit'], 'c' * 40)
        self.assertIsNone(artifacts.snapshot_record(self.manifest, 'windows-x64'))

    def test_attach_appends_windows_record(self):
        manifest = artifacts.attach(self.release, self.bundle)
        record = artifacts.snapshot_record(manifest, 'windows-x64')
        self.assertEqual(record['name'], 'gen_snapshot-windows-x64.exe')
        self.assertEqual(record['verify'], {'snapshot': 'passed', 'device': 'pending', 'device_reason': None})
        self.assertEqual(record['toolchain'], {'visual_studio': '18'})
        self.assertEqual((self.release / 'gen_snapshot-windows-x64.exe').read_bytes(), PE)
        self.assertEqual(artifacts.validate(self.release)['schema'], 2)
        self.assertEqual(len(manifest['files']), 4)
        with self.assertRaisesRegex(ValueError, 'already has a gen_snapshot'):
            artifacts.attach(self.release, self.bundle)

    def test_attach_upgrades_schema_1_in_place(self):
        old = self.downgrade_to_schema_1()
        manifest = artifacts.attach(self.release, self.bundle)
        self.assertEqual(manifest['schema'], 2)
        self.assertEqual(manifest['build_id'], old['build_id'])
        primary = artifacts.snapshot_record(manifest, 'linux-x64')
        self.assertEqual(primary['verify'], old['verify'])
        self.assertEqual(primary['built_at'], old['built_at'])
        self.assertEqual(primary['sha256'], old['files'][2]['sha256'])
        artifacts.validate(self.release)

    def test_schema_1_rejects_extra_record_fields(self):
        manifest = self.downgrade_to_schema_1()
        manifest['files'][2]['verify'] = {'snapshot': 'passed', 'device': 'passed', 'device_reason': None}
        artifacts.write_json(self.release / 'engine.manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'extra fields'):
            artifacts.validate(self.release)

    def test_identity_mismatch_rejected(self):
        for key, value in (('engine_commit', 'f' * 40), ('engine_stamp', 'f' * 40),
                           ('depot_tools_rev', 'f' * 40), ('flutter_version', '3.47.1'),
                           ('patches', [{'file': '0001-fix.patch', 'sha256': 'f' * 64}])):
            with self.subTest(key=key):
                self.write_bundle({**self.host_manifest, key: value})
                with self.assertRaisesRegex(ValueError, f'bundle {key} does not match'):
                    artifacts.attach(self.release, self.bundle)
                self.assertFalse((self.release / 'gen_snapshot-windows-x64.exe').exists())

    def test_unverified_or_wrong_bundle_rejected(self):
        self.write_bundle({**self.host_manifest, 'verify': {'snapshot': 'pending'}})
        with self.assertRaisesRegex(ValueError, 'snapshot verification not passed'):
            artifacts.attach(self.release, self.bundle)
        self.write_bundle({**self.host_manifest, 'host_os': 'linux'})
        with self.assertRaisesRegex(ValueError, 'not a secondary host|invalid gen_snapshot name'):
            artifacts.attach(self.release, self.bundle)
        (self.bundle / 'gen_snapshot-windows-x64.exe').write_bytes(elf(62))
        self.write_bundle({**self.host_manifest, 'file': {
            **self.host_manifest['file'], 'sha256': artifacts.sha256(self.bundle / 'gen_snapshot-windows-x64.exe')}})
        with self.assertRaisesRegex(ValueError, 'not a native executable'):
            artifacts.attach(self.release, self.bundle)

    def test_publishable_requires_every_host_verified(self):
        manifest = artifacts.attach(self.release, self.bundle)
        passed = {'snapshot': 'passed', 'device': 'skipped', 'device_reason': 'no_android_device'}
        manifest['verify'] = dict(passed)
        artifacts.snapshot_record(manifest, 'linux-x64')['verify'] = dict(passed)
        (self.release / 'build.log.zst').write_bytes(b'fixture')
        artifacts.write_json(self.release / 'engine.manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'windows-x64: gen_snapshot verification pending'):
            artifacts.validate(self.release, publishable=True)
        artifacts.snapshot_record(manifest, 'windows-x64')['verify'] = dict(passed)
        artifacts.write_json(self.release / 'engine.manifest.json', manifest)
        artifacts.validate(self.release, publishable=True)

    def test_comparable_ignores_secondary_timestamps(self):
        manifest = artifacts.attach(self.release, self.bundle)
        other = copy.deepcopy(manifest)
        artifacts.snapshot_record(other, 'windows-x64')['built_at'] = '2026-09-20T00:00:00Z'
        self.assertEqual(artifacts.comparable(manifest), artifacts.comparable(other))
        artifacts.snapshot_record(other, 'windows-x64')['size'] += 1
        self.assertNotEqual(artifacts.comparable(manifest), artifacts.comparable(other))


if __name__ == '__main__':
    unittest.main()
