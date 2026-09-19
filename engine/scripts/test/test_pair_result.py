"""pair_device.record_result: which verify blocks a device result updates."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import hosts
import pair_device
from test_hosts import AttachTests, PE, elf  # noqa: F401  (fixtures)

SPEC = importlib.util.spec_from_file_location('artifacts', SCRIPTS / 'artifacts.py')
artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifacts)

PASSED = {'snapshot': 'passed', 'device': 'passed', 'device_reason': None}
SKIPPED = {'snapshot': 'passed', 'device': 'skipped', 'device_reason': 'no_android_device'}


class RecordResultTests(AttachTests):
    def read(self):
        return artifacts.read_json(self.release / 'engine.manifest.json')

    def test_primary_host_updates_release_and_its_record(self):
        manifest = artifacts.attach(self.release, self.bundle)
        pair_device.record_result(self.release, manifest, 'linux-x64', PASSED)
        written = self.read()
        self.assertEqual(written['verify'], PASSED)
        self.assertEqual(artifacts.snapshot_record(written, 'linux-x64')['verify'], PASSED)
        self.assertEqual(artifacts.snapshot_record(written, 'windows-x64')['verify']['device'], 'pending')

    def test_secondary_host_updates_only_its_record(self):
        manifest = artifacts.attach(self.release, self.bundle)
        before = copy.deepcopy(manifest['verify'])
        pair_device.record_result(self.release, manifest, 'windows-x64', SKIPPED)
        written = self.read()
        self.assertEqual(written['verify'], before)
        self.assertEqual(artifacts.snapshot_record(written, 'windows-x64')['verify'], SKIPPED)
        self.assertEqual(artifacts.snapshot_record(written, 'linux-x64')['verify']['device'], 'pending')

    def test_schema_1_updates_release_level_only(self):
        manifest = self.downgrade_to_schema_1()
        pair_device.record_result(self.release, manifest, 'linux-x64', SKIPPED)
        written = self.read()
        self.assertEqual(written['schema'], 1)
        self.assertEqual(written['verify'], SKIPPED)
        self.assertNotIn('verify', written['files'][2])

    def test_unknown_host_record_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'no gen_snapshot for macos-arm64'):
            pair_device.record_result(self.release, self.manifest, 'macos-arm64', PASSED)

    def test_verify_refuses_schema_1_on_secondary_host(self):
        self.downgrade_to_schema_1()
        work = self.root / 'work'
        work.mkdir()
        (work / 'libapp.so').write_bytes(elf(183))
        with patch.object(hosts, 'current', return_value='windows-x64'):
            with self.assertRaisesRegex(ValueError, 'pair only on linux-x64'):
                pair_device.verify(self.release, self.root / 'sdk', work)

    def test_no_device_is_recorded_as_skipped_for_current_host(self):
        artifacts.attach(self.release, self.bundle)
        work = self.root / 'work'
        work.mkdir()
        (work / 'libapp.so').write_bytes(elf(183))
        with patch.object(hosts, 'current', return_value='windows-x64'), \
                patch.object(pair_device.shutil, 'which', return_value=None):
            pair_device.verify(self.release, self.root / 'sdk', work)
        written = self.read()
        self.assertEqual(artifacts.snapshot_record(written, 'windows-x64')['verify'], SKIPPED)
        self.assertEqual(written['verify']['device'], 'pending')


del AttachTests  # do not re-run the inherited suite under this module's name

if __name__ == '__main__':
    unittest.main()
