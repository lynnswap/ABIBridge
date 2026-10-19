#!/usr/bin/env python3
"""Run package tests sequentially on isolated Apple Simulators."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

PLATFORMS = {
    'iOS': ('iphonesimulator', 'iOS', 'iPhone'),
    'tvOS': ('appletvsimulator', 'tvOS', 'Apple TV'),
    'visionOS': ('xrsimulator', 'xrOS', 'Apple Vision'),
    'watchOS': ('watchsimulator', 'watchOS', 'Apple Watch'),
}


def output(*command):
    return subprocess.check_output(command, text=True)


def select_runtime(runtimes, platform, sdk_version):
    _, runtime_platform, family = PLATFORMS[platform]
    candidates = [runtime for runtime in runtimes
                  if runtime.get('isAvailable') and runtime.get('platform') == runtime_platform]
    if not candidates:
        raise RuntimeError(f'No available {platform} Simulator runtime')

    def preference(runtime):
        version = tuple(int(part) for part in runtime['version'].split('.'))
        sdk = tuple(int(part) for part in sdk_version.split('.'))
        return version[:2] == sdk[:2], version

    runtime = max(candidates, key=preference)
    device_type = next((kind for kind in runtime['supportedDeviceTypes']
                        if kind['productFamily'] == family), None)
    if device_type is None:
        raise RuntimeError(f'No {family} device type in {runtime["name"]}')
    return runtime, device_type


def cleanup(device, state_path=None):
    failures = []
    try:
        catalog = json.loads(output('xcrun', 'simctl', 'list', 'devices', '--json'))
        current = next(item for devices in catalog['devices'].values()
                       for item in devices if item['udid'] == device)
        if current['state'] != 'Shutdown':
            subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=True)
    except Exception as error:
        failures.append(f'shutdown {device}: {error}')
    try:
        subprocess.run(['xcrun', 'simctl', 'delete', device], check=True)
        if state_path is not None:
            state_path.unlink(missing_ok=True)
    except Exception as error:
        failures.append(f'delete {device}: {error}')
    return failures


def cleanup_saved_devices(result_dir):
    failures = []
    for state_path in sorted(result_dir.glob('*.device.json')):
        state = json.loads(state_path.read_text())
        failures.extend(cleanup(state['udid'], state_path))
    return failures


def run_platform(platform, root, build_dir, result_dir, test_minutes, only_testing=(),
                 scheme="ABIBridge", build_swiftui=True, collect_test_diagnostics="never"):
    failures = []
    device = None
    state_path = None
    try:
        sdk = PLATFORMS[platform][0]
        runtimes = json.loads(output('xcrun', 'simctl', 'list', 'runtimes', '--json'))['runtimes']
        runtime, kind = select_runtime(runtimes, platform,
                                       output('xcrun', '--sdk', sdk, '--show-sdk-version').strip())
        name = f'ABIBridge-{platform}-{uuid.uuid4().hex[:8]}'
        device = output('xcrun', 'simctl', 'create', name, kind['identifier'], runtime['identifier']).strip()
        result_dir.mkdir(parents=True, exist_ok=True)
        state_path = result_dir / f'{name}.device.json'
        state_path.write_text(json.dumps({'udid': device, 'runtime': runtime['identifier'], 'created': True}))
        print(f'{platform}: {runtime["name"]}, {kind["name"]}, {device}', flush=True)
        common = ['xcodebuild', '-workspace', str(root / 'ABIBridge.xcworkspace'),
                  '-destination', f'platform={platform} Simulator,id={device}',
                  '-derivedDataPath', str(build_dir), 'WATCHOS_DEPLOYMENT_TARGET=11.4',
                  'CODE_SIGNING_ALLOWED=NO']
        try:
            deadline = time.monotonic() + test_minutes * 60
            subprocess.run(['xcrun', 'simctl', 'boot', device], check=True, timeout=60)
            subprocess.run([*common, 'build-for-testing', '-scheme', scheme],
                           cwd=root, check=True, timeout=max(0, deadline - time.monotonic()))
            subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True,
                           timeout=min(300, max(0, deadline - time.monotonic())))
            subprocess.run([*common, 'test-without-building', '-scheme', scheme,
                            '-parallel-testing-enabled', 'NO',
                            '-collect-test-diagnostics', collect_test_diagnostics,
                            '-resultBundlePath', str(result_dir / f'{name}.xcresult'),
                            *[f'-only-testing:{selection}' for selection in only_testing]],
                           cwd=root, check=True, timeout=max(0, deadline - time.monotonic()))
        except Exception as error:
            failures.append(f'{platform} tests: {error}')
        if build_swiftui and any((root / 'Sources/ABIBridgeSwiftUI').glob('*.swift')):
            try:
                subprocess.run([*common, 'build', '-scheme', 'ABIBridgeSwiftUI'],
                               cwd=root, check=True, timeout=5 * 60)
            except Exception as error:
                failures.append(f'{platform} SwiftUI build: {error}')
    except Exception as error:
        failures.append(f'{platform} setup: {error}')
    finally:
        if device is not None:
            failures.extend(cleanup(device, state_path))
    return failures


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platforms', nargs='+', choices=PLATFORMS, default=list(PLATFORMS))
    parser.add_argument('--build-dir', type=Path, default=root / '.build/simulator-tests')
    parser.add_argument('--result-dir', type=Path, default=root / '.build/simulator-results')
    parser.add_argument('--test-minutes', type=int, default=25)
    parser.add_argument('--only-testing', action='append', default=[])
    parser.add_argument('--scheme', default='ABIBridge')
    parser.add_argument('--skip-swiftui-build', action='store_true')
    parser.add_argument('--collect-test-diagnostics', choices=('never', 'on-failure'),
                        default='never', help='Collect verbose failure diagnostics such as sysdiagnose')
    parser.add_argument('--cleanup', action='store_true', help='Clean up devices left by an interrupted run')
    args = parser.parse_args()
    args.result_dir.mkdir(parents=True, exist_ok=True)
    failures = cleanup_saved_devices(args.result_dir) if args.cleanup else []
    if not args.cleanup:
        for platform in args.platforms:
            failures.extend(run_platform(platform, root, args.build_dir.resolve(),
                                         args.result_dir.resolve(), args.test_minutes, args.only_testing,
                                         args.scheme, not args.skip_swiftui_build, args.collect_test_diagnostics))
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
