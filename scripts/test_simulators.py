"""Lifecycle and failure coverage for the Simulator validation helper."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('simulators', Path(__file__).with_name('test-simulators.py'))
simulators = importlib.util.module_from_spec(spec)
spec.loader.exec_module(simulators)


def runtime(version):
    return {'isAvailable': True, 'platform': 'iOS', 'version': version,
            'name': 'iOS ' + version, 'identifier': 'runtime-' + version,
            'supportedDeviceTypes': [{'productFamily': 'iPhone', 'identifier': 'iphone', 'name': 'iPhone'}]}


class SimulatorTests(unittest.TestCase):
    def test_matching_sdk_is_preferred_to_a_newer_installed_runtime(self):
        selected, _ = simulators.select_runtime([runtime('27.0'), runtime('26.5')], 'iOS', '26.5')
        self.assertEqual(selected['version'], '26.5')

    def test_available_runtime_is_used_when_the_sdk_version_has_no_exact_match(self):
        selected, _ = simulators.select_runtime([runtime('26.4'), runtime('26.5')], 'iOS', '26.6')
        self.assertEqual(selected['version'], '26.5')

    def test_failed_tests_still_build_swiftui_and_clean_only_the_created_device(self):
        calls = []

        def output(*args):
            if 'runtimes' in args:
                return json.dumps({'runtimes': [runtime('26.5')]})
            if '--show-sdk-version' in args:
                return '26.5\n'
            if 'create' in args:
                return 'owned-device\n'
            return json.dumps({'devices': {'runtime': [
                {'udid': 'owned-device', 'state': 'Booted'},
                {'udid': 'other-task-device', 'state': 'Booted'}]}})

        def run(args, **kwargs):
            calls.append(args)
            if args[:3] == ['xcrun', 'simctl', 'boot']:
                states = list((root / 'results').glob('*.device.json'))
                self.assertEqual(len(states), 1)
                self.assertEqual(json.loads(states[0].read_text())['udid'], 'owned-device')
            if 'test-without-building' in args:
                raise subprocess.CalledProcessError(65, args)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Sources/ABIBridgeSwiftUI'
            source.mkdir(parents=True)
            (source / 'View.swift').touch()
            with patch.object(simulators, 'output', side_effect=output), patch.object(simulators.subprocess, 'run', side_effect=run):
                failures = simulators.run_platform('iOS', root, root / 'build', root / 'results', 25)
        self.assertEqual(len(failures), 1)
        self.assertIn('iOS tests', failures[0])
        test = next(call for call in calls if 'test-without-building' in call)
        self.assertEqual(test[test.index('-collect-test-diagnostics') + 1], 'never')
        self.assertIn('-resultBundlePath', test)
        boot = ['xcrun', 'simctl', 'boot', 'owned-device']
        build = next(call for call in calls if 'build-for-testing' in call)
        join = ['xcrun', 'simctl', 'bootstatus', 'owned-device', '-b']
        self.assertLess(calls.index(boot), calls.index(build))
        self.assertLess(calls.index(build), calls.index(join))
        self.assertLess(calls.index(join), calls.index(test))
        self.assertIn('platform=iOS Simulator,id=owned-device', build)
        self.assertIn('platform=iOS Simulator,id=owned-device', test)
        self.assertTrue(any('ABIBridgeSwiftUI' in call for call in calls))
        self.assertIn(['xcrun', 'simctl', 'shutdown', 'owned-device'], calls)
        self.assertIn(['xcrun', 'simctl', 'delete', 'owned-device'], calls)
        self.assertFalse(any('other-task-device' in call for call in calls))

    def test_runtime_scheme_does_not_build_the_upper_product(self):
        def output(*args):
            if 'runtimes' in args:
                return json.dumps({'runtimes': [runtime('27.0')]})
            if '--show-sdk-version' in args:
                return '27.0'
            if 'create' in args:
                return 'owned-device'
            return json.dumps({'devices': {'runtime': [
                {'udid': 'owned-device', 'state': 'Shutdown'}]}})

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Sources/ABIBridgeSwiftUI'
            source.mkdir(parents=True)
            (source / 'View.swift').touch()
            with patch.object(simulators, 'output', side_effect=output), \
                    patch.object(simulators.subprocess, 'run') as run:
                failures = simulators.run_platform(
                    'iOS', root, root / 'build', root / 'results', 10,
                    scheme='ABIBridgeRuntime', build_swiftui=False,
                    collect_test_diagnostics='on-failure')
        self.assertEqual(failures, [])
        commands = [call.args[0] for call in run.call_args_list]
        builds = [command for command in commands if command[0] == 'xcodebuild']
        self.assertEqual(len(builds), 2)
        self.assertIn('ABIBridgeRuntime', builds[0])
        self.assertNotIn('ABIBridgeSwiftUI', builds[0])
        self.assertEqual(builds[1][builds[1].index('-collect-test-diagnostics') + 1], 'on-failure')
        self.assertIn(['xcrun', 'simctl', 'delete', 'owned-device'], commands)

    def test_boot_or_build_failure_preserves_failed_cleanup_for_the_workflow(self):
        catalog = json.dumps({'devices': {'runtime': [
            {'udid': 'owned-device', 'state': 'Booted'},
            {'udid': 'other-device', 'state': 'Booted'}]}})
        for stage in ('boot', 'build-for-testing'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                def fail(args, **kwargs):
                    if stage in args or 'delete' in args:
                        raise subprocess.CalledProcessError(1, args)
                with patch.object(simulators, 'output', side_effect=[
                        json.dumps({'runtimes': [runtime('26.5')]}), '26.5', 'owned-device', catalog]), \
                        patch.object(simulators.subprocess, 'run', side_effect=fail) as run:
                    failures = simulators.run_platform(
                        'iOS', root, root / 'build', root / 'results', 25, build_swiftui=False)
                self.assertEqual(len(failures), 2)
                self.assertFalse(any('test-without-building' in call.args[0] for call in run.call_args_list))
                self.assertEqual(len(list((root / 'results').glob('*.device.json'))), 1)
                with patch.object(simulators, 'output', return_value=catalog), \
                        patch.object(simulators.subprocess, 'run') as cleanup:
                    self.assertEqual(simulators.cleanup_saved_devices(root / 'results'), [])
                self.assertIn(unittest.mock.call(['xcrun', 'simctl', 'delete', 'owned-device'], check=True),
                              cleanup.call_args_list)
                self.assertFalse(any('other-device' in call.args[0] for call in cleanup.call_args_list))
                self.assertEqual(list((root / 'results').glob('*.device.json')), [])

    def test_both_shutdown_and_deletion_failures_remain_observable(self):
        catalog = {'devices': {'runtime': [{'udid': 'owned-device', 'state': 'Booted'}]}}
        with patch.object(simulators, 'output', return_value=json.dumps(catalog)), \
                patch.object(simulators.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'cleanup')) as run:
            failures = simulators.cleanup('owned-device')
        self.assertEqual(run.call_count, 2)
        self.assertEqual(len(failures), 2)
        self.assertTrue(failures[0].startswith('shutdown'))
        self.assertTrue(failures[1].startswith('delete'))

    def test_shutdown_devices_are_deleted_without_a_redundant_shutdown(self):
        catalog = {'devices': {'runtime': [{'udid': 'owned-device', 'state': 'Shutdown'}]}}
        with patch.object(simulators, 'output', return_value=json.dumps(catalog)), patch.object(simulators.subprocess, 'run') as run:
            self.assertEqual(simulators.cleanup('owned-device'), [])
        run.assert_called_once_with(['xcrun', 'simctl', 'delete', 'owned-device'], check=True)


if __name__ == '__main__':
    unittest.main()
