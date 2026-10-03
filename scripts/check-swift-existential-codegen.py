#!/usr/bin/env python3
"""Compare existential call lowering and closure authentication with Swift."""
import json
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def function(ir, name):
    symbol = r'@"\$s20ManagedSwiftFixtures' + str(len(name)) + re.escape(name)
    match = re.search(r'^define[^\n]*' + symbol + r'[^\n]*\{.*?^}', ir, re.M | re.S)
    if not match:
        raise RuntimeError('Missing function: ' + name)
    return match[0]


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swift-existential-codegen'
    reports = []
    for target, sdk_name in [('arm64-apple-macos15.4', 'macosx'), ('x86_64-apple-macos15.4', 'macosx'),
                             ('arm64e-apple-ios18.4', 'iphoneos'), ('arm64_32-apple-watchos11.4', 'watchos')]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run('xcrun', '--sdk', sdk_name, '--show-sdk-path').strip()
        provider = [str(root / 'Tests/ManagedSwiftFixtures' / name) for name in ['Errors.swift', 'Async.swift', 'RuntimeValues.swift', 'Existentials.swift']]
        ir_path = directory / 'provider.ll'
        run('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-enable-library-evolution',
            '-whole-module-optimization', '-Onone', '-module-name', 'ManagedSwiftFixtures',
            '-target', target, '-sdk', sdk, '-emit-ir', *provider, '-o', str(ir_path))
        ir = ir_path.read_text()
        signatures = {}
        for name in ['echoAny', 'echoExistential', 'echoComposition', 'echoClassExistential',
                     'echoManyClassExistential', 'echoErrorExistential', 'echoOptionalExistential',
                     'echoOptionalAny', 'echoOptionalClass', 'echoOptionalError', 'echoClassErrorExistential']:
            line = function(ir, name).splitlines()[0]
            indirect = name in ['echoAny', 'echoExistential', 'echoComposition', 'echoManyClassExistential',
                                'echoOptionalExistential', 'echoOptionalAny']
            if ('sret(' in line) != indirect:
                raise RuntimeError(f'{target}: re-evaluate {name}: {line}')
            if indirect and 'dereferenceable(' not in line:
                raise RuntimeError(f'{target}: expected a borrowed container address: {line}')
            if name == 'echoClassExistential' and not line.startswith('define swiftcc { ptr, ptr }'):
                raise RuntimeError(f'{target}: expected object and witness pointers: {line}')
            if name == 'echoErrorExistential' and not line.startswith('define swiftcc ptr'):
                raise RuntimeError(f'{target}: expected an error box pointer: {line}')
            if name == 'echoClassErrorExistential' and not line.startswith('define swiftcc { ptr, ptr }'):
                raise RuntimeError(f'{target}: re-evaluate class-constrained Error storage mismatch: {line}')
            signatures[name] = line
        discriminators = {}
        if target.startswith('arm64e'):
            for name, expected in {'applyAnyExistentialClosure': 55683, 'applyExistentialClosure': 55683,
                                   'applyClassExistentialClosure': 59948, 'applyManyClassExistentialClosure': 59948,
                                   'applyErrorExistentialClosure': 30340, 'applyOptionalClassClosure': 30130,
                                   'applyOptionalErrorClosure': 1845}.items():
                values = re.findall(r'"ptrauth"\(i32 0, i64 (\d+)\)', function(ir, name))
                if values != [str(expected)]:
                    raise RuntimeError(f'{target}: re-evaluate authentication for {name}: {values}')
                discriminators[name] = expected
        reports.append({'target': target, 'signatures': signatures, 'discriminators': discriminators})
    report = {'compiler': run('xcrun', 'swiftc', '--version').strip(), 'runtimeTested': False, 'targets': reports}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
