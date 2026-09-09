import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import source_state


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'WP1 test')
        self.git('config', 'user.email', 'wp1@example.invalid')
        (self.root / 'source.cc').write_text('original\n')
        self.git('add', 'source.cc')
        self.git('commit', '-qm', 'fixture')
        self.bash = os.environ.get('WP1_TEST_BASH', shutil.which('bash'))

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def shell(self, function, *args):
        self.assertIsNotNone(self.bash, 'bash is required for pipeline assertion tests')
        return subprocess.run([self.bash, '-c', 'source "$1"; shift; "$@"',
                               'test', (SCRIPTS / 'common.sh').as_posix(), function,
                               *[Path(arg).as_posix() if isinstance(arg, Path) else arg for arg in args]],
                              capture_output=True, text=True)

    def test_wrong_commit_exits_nonzero(self):
        result = self.shell('assert_commit', self.root, 'a' * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checkout commit mismatch', result.stderr)

    def test_invalid_commit_exits_nonzero(self):
        result = self.shell('assert_commit', self.root, '--help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('40 lowercase', result.stderr)

    def test_matching_commit_passes(self):
        result = self.shell('assert_commit', self.root, self.git('rev-parse', 'HEAD'))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_gn_and_command_fail_before_build(self):
        missing = self.shell('assert_gn', self.root / 'absent.gn')
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('args.gn missing', missing.stderr)
        command = self.shell('require_commands', 'wp9-command-that-does-not-exist')
        self.assertNotEqual(command.returncode, 0)
        self.assertIn('required command missing', command.stderr)

    def test_wrong_host_and_dirty_builder_fail(self):
        for body, message in [
            ('uname() { echo Darwin; }; assert_host', 'requires Linux x86_64'),
            ('WP1_HOME=relative; assert_host', 'absolute managed directory'),
            ('WP1_REPO="$2"; assert_clean_builder', 'builder repository is dirty'),
        ]:
            (self.root / 'untracked.txt').write_text('deliberately dirty')
            result = subprocess.run([self.bash, '-c', 'source "$1"; ' + body,
                                     'test', str(SCRIPTS / 'common.sh'), str(self.root)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)

    def test_missing_false_and_commented_dynamic_module_flag_fail(self):
        args = self.root / 'args.gn'
        for content in ('target_cpu = "arm64"\n', 'dart_dynamic_modules = false\n',
                        '# dart_dynamic_modules = true\n'):
            args.write_text(content)
            result = self.shell('assert_gn', args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('dart_dynamic_modules is not true', result.stderr)
        args.write_text('dart_dynamic_modules = true\n')
        self.assertEqual(self.shell('assert_gn', args).returncode, 0)

    def test_unsupported_abi_fails(self):
        self.assertNotEqual(self.shell('assert_abi', 'x86_64').returncode, 0)
        self.assertEqual(self.shell('assert_abi', 'arm64-v8a').returncode, 0)

    def test_unsupported_version_and_shell_input_rejected(self):
        for version in ('1.0.0', '../3.47.2', '3.47.2;echo injected'):
            self.assertNotEqual(self.shell('assert_version', version).returncode, 0)

    def test_patch_drift_is_not_accepted(self):
        patch = SCRIPTS.parents[1] / 'engine_patches/0001-dyn-module-factory-allocate-finalize.patch'
        result = subprocess.run(['git', '-C', str(self.root), 'apply', '--check', str(patch)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'source.cc').read_text(), 'original\n')

    def test_dirty_dependency_is_rejected(self):
        source_state.check_clean(self.root)
        (self.root / 'source.cc').write_text('unexpected edit\n')
        with self.assertRaisesRegex(ValueError, 'tracked edits'):
            source_state.check_clean(self.root)

    def test_full_index_patch_is_independent_of_git_abbreviation(self):
        (self.root / 'source.cc').write_text('patched\n')
        short = self.git('-c', 'core.abbrev=8', 'diff', '--full-index', '--binary', 'HEAD')
        long = self.git('-c', 'core.abbrev=11', 'diff', '--full-index', '--binary', 'HEAD')
        self.assertEqual(short, long)

    def test_gclient_entries_cannot_execute_code(self):
        (self.root / '.gclient_entries').write_text('entries = __import__("os").getcwd()')
        with self.assertRaises(ValueError):
            source_state.check_clean(self.root)

    def test_gclient_path_escape_rejected(self):
        (self.root / '.gclient_entries').write_text('entries = {"../outside": "git"}')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            source_state.check_clean(self.root)


if __name__ == '__main__':
    unittest.main()
