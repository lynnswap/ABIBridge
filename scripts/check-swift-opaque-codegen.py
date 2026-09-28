#!/usr/bin/env python3
"""Verify opaque result descriptors, indirect calls, and compiler erasure."""
import json
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swift-opaque-codegen'
    reports = []
    for target, sdk_name in [('arm64-apple-macos15.4', 'macosx'), ('x86_64-apple-macos15.4', 'macosx'),
                             ('arm64e-apple-ios18.4', 'iphoneos'), ('arm64_32-apple-watchos11.4', 'watchos')]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run('xcrun', '--sdk', sdk_name, '--show-sdk-path').strip()
        common = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-Onone', '-target', target, '-sdk', sdk]
        provider = [*common, '-whole-module-optimization', '-enable-library-evolution', '-module-name', 'ManagedSwiftFixtures',
                    *[str(root / 'Tests/ManagedSwiftFixtures' / name) for name in ['Errors.swift', 'Async.swift', 'Existentials.swift', 'OpaqueResults.swift']]]
        run(*provider, '-emit-module', '-emit-module-path', str(directory / 'ManagedSwiftFixtures.swiftmodule'))
        run(*provider, '-emit-ir', '-o', str(directory / 'provider.ll'))
        run(*common, '-module-name', 'OpaqueAdapterProbe', '-I', str(directory), '-emit-ir',
            str(root / 'Tests/ManagedSwiftAdapters/OpaqueResultAdapters.swift'), '-o', str(directory / 'caller.ll'))
        text = (directory / 'provider.ll').read_text()
        caller = (directory / 'caller.ll').read_text()
        declarations = {}
        direct = ['makeOpaqueClassAny', 'makeOpaqueClassProtocol', 'makeOpaqueSuperclass', 'makeOpaqueObjC']
        names = ['makeOpaque', 'makeOpaqueInteger', 'makeOpaqueEmpty', 'makeOpaqueThrowing', 'makeOpaqueAsync',
                 'makeOpaqueUnconstrainedClass', 'makeOpaqueClassAsync', *direct]
        for name in names:
            # Avoid treating makeOpaqueInteger as makeOpaque; manglings spell the identifier length.
            fragment = str(len(name)) + name
            lines = [line for line in caller.splitlines() if line.startswith('declare ') and fragment in line]
            if len(lines) != 1:
                raise RuntimeError(f'{target}: missing opaque caller declaration for {name}: {lines}')
            line = lines[0]
            if name == 'makeOpaqueAsync':
                if 'swifttailcc void' not in line or not re.search(r'\(ptr[^,]*, ptr swiftasync', line):
                    raise RuntimeError(f'{target}: async opaque output must be the leading ordinary pointer: {line}')
            elif name == 'makeOpaqueClassAsync':
                if 'swifttailcc void' not in line or not re.search(r'\(ptr swiftasync', line):
                    raise RuntimeError(f'{target}: class-constrained async result must not add an output pointer: {line}')
            elif name in direct:
                if not line.startswith('declare swiftcc ptr '):
                    raise RuntimeError(f'{target}: class-constrained opaque result must be direct: {line}')
            elif 'swiftcc void' not in line or 'sret(' not in line:
                raise RuntimeError(f'{target}: opaque outputs must remain indirect: {line}')
            declarations[name] = line
        descriptors = {}
        for name in [*names, 'makeGenericOpaque', 'makeNoncopyableOpaque']:
            fragment = str(len(name)) + name
            lines = [line for line in text.splitlines() if line.startswith('@') and fragment in line and 'QOMQ" = ' in line]
            if len(lines) != 1:
                raise RuntimeError(f'{target}: missing opaque descriptor for {name}')
            line = lines[0]
            flags = int(re.search(r'> <\{ i32 (\d+)', line)[1])
            header = [int(value) for value in re.findall(r'i16 (-?\d+)', line)]
            if flags & 0x1f != 4 or not flags & 0x80 or header[0] < 1:
                raise RuntimeError(f'{target}: re-evaluate descriptor header: {name}')
            captured = header[2] - (flags >> 16)
            if (captured > 0) != (name == 'makeGenericOpaque'):
                raise RuntimeError(f'{target}: re-evaluate captured opaque metadata: {name}')
            if name == 'makeNoncopyableOpaque' and not (header[-2:] == [0, 1] and 'i32 5,' in line):
                raise RuntimeError(f'{target}: re-evaluate the noncopyable result requirement')
            descriptors[name] = {'flags': flags, 'header': header[:4], 'capturedArguments': captured}
        if 'getTypeByMangledNameInContext' not in caller or 'InitializeWithCopy' not in caller:
            raise RuntimeError(f'{target}: missing compiler metadata/copy evidence for Any erasure')
        reports.append({'target': target, 'declarations': declarations, 'descriptors': descriptors})
    report = {'compiler': run('xcrun', 'swiftc', '--version').strip(), 'runtimeTested': False, 'targets': reports}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
