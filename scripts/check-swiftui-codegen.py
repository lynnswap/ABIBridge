#!/usr/bin/env python3
"""Verify SwiftUI value lowering using an independently compiled client."""
import json
from pathlib import Path
import re
import subprocess


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swiftui-codegen'
    reports = []
    for target, sdk_name, word in [('arm64-apple-macos15.4', 'macosx', 'i64'), ('x86_64-apple-macos15.4', 'macosx', 'i64'),
                                   ('arm64e-apple-ios18.4', 'iphoneos', 'i64'), ('arm64_32-apple-watchos11.4', 'watchos', 'i32')]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run('xcrun', '--sdk', sdk_name, '--show-sdk-path').strip()
        common = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-Onone', '-target', target, '-sdk', sdk]
        run(*common, '-enable-library-evolution', '-module-name', 'SwiftUIFixtures', '-emit-module',
            str(root / 'Tests/ArchitectureValidation/Sources/SwiftUIFixtures/Provider.swift'),
            '-emit-module-path', str(directory / 'SwiftUIFixtures.swiftmodule'))
        run(*common, '-I', str(directory), '-emit-ir',
            str(root / 'Tests/ArchitectureValidation/CompilerProbes/SwiftUI.swift'), '-o', str(directory / 'caller.ll'))
        ir = (directory / 'caller.ll').read_text()
        signatures = {}
        for name in ['echoText', 'echoImage', 'echoColor', 'echoAnyView', 'echoContainer', 'wrap', 'makeComposedPanel']:
            lines = [line for line in ir.splitlines() if line.startswith('declare swiftcc') and f'{len(name)}{name}' in line]
            if len(lines) != 1:
                raise RuntimeError(f'{target}: missing compiler signature for {name}: {lines}')
            line = lines[0]
            if name in ['echoImage', 'echoColor', 'echoAnyView'] and not line.startswith('declare swiftcc ptr '):
                raise RuntimeError(f'{target}: expected one owned provider reference: {line}')
            if name in ['echoContainer', 'wrap', 'makeComposedPanel'] and 'sret(' not in line:
                raise RuntimeError(f'{target}: expected indirect generic/opaque result: {line}')
            if name == 'echoText' and word == 'i64' and not line.startswith('declare swiftcc { i64, i64, i8, ptr }'):
                raise RuntimeError(f'{target}: re-evaluate frozen Text storage/tag/modifiers: {line}')
            if name == 'echoText' and word == 'i32' and not line.startswith('declare swiftcc { i32, i32, i32, ptr }'):
                raise RuntimeError(f'{target}: re-evaluate 32-bit Text storage/tag/modifiers: {line}')
            signatures[name] = line
        parameters = signatures['wrap'].split('"(', 1)[1].rsplit(')', 1)[0].split(', ')
        if len(parameters) != 4 or parameters[-2:] != ['ptr', 'ptr']:
            raise RuntimeError(f'{target}: generic Container needs value metadata and View witness arguments')
        reports.append({'target': target, 'signatures': signatures})
    report = {'compiler': run('xcrun', 'swiftc', '--version').strip(), 'runtimeTested': False, 'targets': reports}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
