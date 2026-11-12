"""Process and failure coverage for the package test helper."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class PackageTests(unittest.TestCase):
    GROUPS = ['group-1', 'group-2', 'group-3', 'group-4']

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
            group = Path(args[args.index('-resultBundlePath') + 1]).stem
            groups = os.environ['STUB_GROUPS'].split()
            (root / (group + '.json')).write_text(json.dumps(args))
            (root / (group + '.started')).touch()
            deadline = time.monotonic() + 5
            while not all((root / (other + '.started')).exists() for other in groups):
                if time.monotonic() > deadline:
                    sys.exit(70)
                time.sleep(0.01)
            if group == groups[-1]:
                time.sleep(0.1)
            (root / (group + '.finished')).touch()
            sys.exit(65 if group == os.environ.get('STUB_FAILING_GROUP') else 0)
        '''))
        self.stub.chmod(0o755)

    def run_package(self, groups, **overrides):
        for pattern in ['*.started', '*.finished']:
            for marker in self.root.glob(pattern):
                marker.unlink()
        environment = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                           ABI_TEST_PARALLEL_API='1', ABI_TEST_BUILD_DIR=str(self.root / 'build'),
                           STUB_LOG_DIR=str(self.root), STUB_GROUPS=' '.join(groups), **overrides)
        return subprocess.run(
            ['bash', str(Path(__file__).with_name('test-package.sh')), 'api', '-configuration', 'Release'],
            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)

    def command(self, name):
        return json.loads((self.root / (name + '.json')).read_text())

    def test_build_is_reused_by_concurrent_complementary_groups(self):
        self.assertEqual(self.run_package(self.GROUPS).returncode, 0)
        build = self.command('build')
        named = [self.command(group) for group in self.GROUPS[:3]]
        remaining = self.command(self.GROUPS[3])
        self.assertEqual(build[0], 'build-for-testing')
        only = []
        for command in named:
            self.assertEqual(command[0], 'test-without-building')
            suites = [arg.removeprefix('-only-testing:') for arg in command if arg.startswith('-only-testing:')]
            self.assertTrue(suites)
            self.assertFalse(any(arg.startswith('-skip-testing:') for arg in command))
            only += suites
        self.assertEqual(len(only), len(set(only)))
        self.assertEqual(remaining[0], 'test-without-building')
        skip = [arg.removeprefix('-skip-testing:') for arg in remaining if arg.startswith('-skip-testing:')]
        self.assertEqual(only, skip)
        self.assertTrue(all(suite.startswith('ABIBridgeTests/') and suite.count('/') == 1 for suite in only))
        self.assertFalse(any(arg.startswith('-only-testing:') for arg in remaining))
        for command in [build, remaining] + named:
            self.assertEqual(command[command.index('-derivedDataPath') + 1], str(self.root / 'build'))
            self.assertEqual(command[command.index('-configuration') + 1], 'Release')
        result_paths = set()
        for command in named + [remaining]:
            self.assertEqual(command[command.index('-parallel-testing-enabled') + 1], 'NO')
            result_paths.add(Path(command[command.index('-resultBundlePath') + 1]))
        self.assertEqual(len(result_paths), 4)
        self.assertTrue(all(path.is_relative_to(self.root / 'build/Logs/Test') for path in result_paths))

    def test_a_part_runs_its_two_groups(self):
        for part, groups in [('1', self.GROUPS[:2]), ('2', self.GROUPS[2:])]:
            with self.subTest(part=part):
                self.assertEqual(self.run_package(groups, ABI_TEST_API_PART=part).returncode, 0)
                self.assertEqual(sorted(marker.stem for marker in self.root.glob('*.started')), groups)

    def test_any_failure_is_reported_after_every_group_finishes(self):
        for group in self.GROUPS:
            with self.subTest(group=group):
                self.assertNotEqual(self.run_package(self.GROUPS, STUB_FAILING_GROUP=group).returncode, 0)
                for other in self.GROUPS:
                    self.assertTrue((self.root / (other + '.finished')).exists())

    def test_build_failure_does_not_start_test_processes(self):
        self.assertNotEqual(self.run_package(self.GROUPS, STUB_BUILD_EXIT='65').returncode, 0)
        self.assertTrue((self.root / 'build.json').exists())
        self.assertFalse(list(self.root.glob('*.started')))


if __name__ == '__main__':
    unittest.main()
