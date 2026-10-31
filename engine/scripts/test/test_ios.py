from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import artifacts

PATCHED = artifacts.MACHO_ARM64 + b'patched'


class IosPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.stock = root / 'stock/Flutter.xcframework'
        for slice_, data in (('ios-arm64', b'stock'), ('ios-arm64_x86_64-simulator', b'simulator')):
            (self.stock / slice_ / 'Flutter.framework').mkdir(parents=True)
            (self.stock / slice_ / 'Flutter.framework/Flutter').write_bytes(data)
        (self.stock / 'Info.plist').write_text('<plist/>')
        (self.stock / '_CodeSignature').mkdir()
        (self.stock / '_CodeSignature/CodeResources').write_text('stale')
        self.framework = root / 'out/Flutter.framework'
        self.framework.mkdir(parents=True)
        (self.framework / 'Flutter').write_bytes(PATCHED)
        self.snapshot = root / 'out/gen_snapshot_arm64'
        self.snapshot.write_bytes(b'\xcf\xfa\xed\xfe' + bytes(60))
        self.release = root / 'release'
        self.identity = {'flutter_version': '3.47.2', 'engine_commit': 'a' * 40, 'builder_repo_commit': 'c' * 40,
                         'depot_tools_rev': 'd' * 40, 'patches': [{'file': '0001-fix.patch', 'sha256': 'e' * 64}],
                         'toolchain': {'xcode': '26.6 (17F42)'}}

    def tearDown(self):
        self.temp.cleanup()

    def package(self):
        return artifacts.package_ios(self.framework, self.stock, self.snapshot, self.identity,
                                     {'snapshot': 'passed', 'device': 'skipped', 'device_reason': 'no_ios_device'},
                                     self.release)

    def test_device_slice_is_replaced_and_the_rest_kept(self):
        manifest = self.package()
        with zipfile.ZipFile(self.release / artifacts.IOS_FRAMEWORK_ZIP) as archive:
            self.assertEqual(archive.read(artifacts.IOS_FRAMEWORK_BINARY), PATCHED)
            self.assertEqual(archive.read('Flutter.xcframework/ios-arm64_x86_64-simulator/Flutter.framework/Flutter'),
                             b'simulator')
            self.assertFalse(any('_CodeSignature' in name for name in archive.namelist()))
        self.assertEqual(manifest['toolchain'], self.identity['toolchain'])
        self.assertFalse((self.release / '.xcframework').exists())

    def test_tampered_framework_is_rejected(self):
        manifest = self.package()
        manifest['files'][0]['contents'][0]['sha256'] = 'f' * 64
        artifacts.write_json(self.release / 'engine-ios.manifest.json', manifest)
        with self.assertRaisesRegex(artifacts.InvalidArtifact, 'device binary mismatch'):
            artifacts.validate_ios(self.release)


if __name__ == '__main__':
    unittest.main()