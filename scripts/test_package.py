"""Process and failure coverage for the package test helper."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.stub = self.root / 'xcodebuild'
        self.stub.write_text(textwrap.dedent('''\
            #!/usr/bin/env python3
            import json
            import os
            from pathlib import Path
            import sys
            import time

            root = Path(os.environ['STUB_LOG_DIR'])
            args = sys.argv[1:]
            if args[0] == 'build-for-testing':
                (root / 'build.json').write_text(json.dumps(args))
                sys.exit(int(os.environ.get('STUB_BUILD_EXIT', '0')))
            group = 'selected' if any(arg.startswith('-only-testing:') for arg in args) else 'remaining'
            (root / (group + '.json')).write_text(json.dumps(args))
            (root / (group + '.started')).touch()
            other = 'remaining' if group == 'selected' else 'selected'
            deadline = time.monotonic() + 5
            while not (root / (other + '.started')).exists():
                if time.monotonic() > deadline:
                    sys.exit(70)
                time.sleep(0.01)
            if group == 'remaining':
                time.sleep(0.1)
            (root / (group + '.finished')).touch()
            sys.exit(int(os.environ.get('STUB_' + group.upper() + '_EXIT', '0')))
        '''))
        self.stub.chmod(0o755)

    def run_package(self, **overrides):
        environment = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                           ABI_TEST_PARALLEL_API='1', ABI_TEST_BUILD_DIR=str(self.root / 'build'),
                           STUB_LOG_DIR=str(self.root), **overrides)
        return subprocess.run(
            ['bash', str(Path(__file__).with_name('test-package.sh')), 'api', '-configuration', 'Release'],
            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)

    def command(self, name):
        return json.loads((self.root / (name + '.json')).read_text())

    def test_build_is_reused_by_concurrent_complementary_groups(self):
        self.assertEqual(self.run_package().returncode, 0)
        build = self.command('build')
        selected = self.command('selected')
        remaining = self.command('remaining')
        self.assertEqual(build[0], 'build-for-testing')
        self.assertEqual(selected[0], 'test-without-building')
        self.assertEqual(remaining[0], 'test-without-building')
        only = [arg.removeprefix('-only-testing:') for arg in selected if arg.startswith('-only-testing:')]
        skip = [arg.removeprefix('-skip-testing:') for arg in remaining if arg.startswith('-skip-testing:')]
        self.assertTrue(only)
        self.assertEqual(only, skip)
        self.assertTrue(all(suite.startswith('ABIBridgeTests/') and suite.count('/') == 1 for suite in only))
        self.assertFalse(any(arg.startswith('-skip-testing:') for arg in selected))
        self.assertFalse(any(arg.startswith('-only-testing:') for arg in remaining))
        for command in [build, selected, remaining]:
            self.assertEqual(command[command.index('-derivedDataPath') + 1], str(self.root / 'build'))
            self.assertEqual(command[command.index('-configuration') + 1], 'Release')
        result_paths = []
        for command in [selected, remaining]:
            self.assertEqual(command[command.index('-parallel-testing-enabled') + 1], 'NO')
            result_paths.append(Path(command[command.index('-resultBundlePath') + 1]))
        self.assertNotEqual(*result_paths)
        self.assertTrue(all(path.is_relative_to(self.root / 'build/Logs/Test') for path in result_paths))

    def test_either_failure_is_reported_after_both_groups_finish(self):
        for group in ['SELECTED', 'REMAINING']:
            with self.subTest(group=group):
                for marker in self.root.glob('*.started'):
                    marker.unlink()
                for marker in self.root.glob('*.finished'):
                    marker.unlink()
                self.assertNotEqual(self.run_package(**{'STUB_' + group + '_EXIT': '65'}).returncode, 0)
                self.assertTrue((self.root / 'selected.finished').exists())
                self.assertTrue((self.root / 'remaining.finished').exists())

    def test_build_failure_does_not_start_test_processes(self):
        self.assertNotEqual(self.run_package(STUB_BUILD_EXIT='65').returncode, 0)
        self.assertTrue((self.root / 'build.json').exists())
        self.assertFalse((self.root / 'selected.started').exists())
        self.assertFalse((self.root / 'remaining.started').exists())


if __name__ == '__main__':
    unittest.main()
