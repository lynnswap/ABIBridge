#!/usr/bin/env python3
"""Record async entry, context, completion, and executor ABI evidence."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def parameters(declaration):
    return declaration.split('"(', 1)[1].rsplit(')', 1)[0].split(', ')


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swift-async-codegen'
    reports = []
    counts = {'asyncImmediate': 4, 'asyncConcurrent': 4, 'asyncCaller': 5,
              'asyncMainActor': 2, 'asyncUntyped': 4, 'asyncTyped': 4,
              'asyncBothIndirect': 6, 'asyncFloatingError': 4, 'asyncMany': 21}
    for target, sdk_name, bits in [
        ('arm64-apple-macos15.4', 'macosx', 64),
        ('x86_64-apple-macos15.4', 'macosx', 64),
        ('arm64e-apple-ios18.4', 'iphoneos', 64),
        ('arm64_32-apple-watchos11.4', 'watchos', 32),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run('xcrun', '--sdk', sdk_name, '--show-sdk-path').strip()
        common = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-Onone',
                  '-target', target, '-sdk', sdk]
        provider = [*common, '-whole-module-optimization', '-enable-library-evolution',
                    '-module-name', 'ManagedSwiftFixtures',
                    str(root / 'Tests/ManagedSwiftFixtures/Errors.swift'),
                    str(root / 'Tests/ManagedSwiftFixtures/Async.swift')]
        run(*provider, '-emit-module', '-emit-module-path', str(directory / 'ManagedSwiftFixtures.swiftmodule'))
        provider_ir = directory / 'provider.ll'
        run(*provider, '-emit-ir', '-o', str(provider_ir))
        adapter_ir = directory / 'adapters.ll'
        run(*common, '-module-name', 'AsyncAdapterProbe', '-I', str(directory), '-emit-ir',
            str(root / 'Tests/ManagedSwiftAdapters/AsyncAdapters.swift'), '-o', str(adapter_ir))
        text = provider_ir.read_text()
        caller = adapter_ir.read_text()
        declarations, context_sizes = {}, {}
        for name, count in counts.items():
            lines = [line for line in caller.splitlines()
                     if line.startswith('declare swifttailcc') and name in line and 'Fixtures' in line]
            if len(lines) != 1 or 'swiftasync' not in lines[0] or len(parameters(lines[0])) != count:
                raise RuntimeError(f'{target}: re-evaluate async signature for {name}: {lines}')
            declarations[name] = lines[0]
            descriptors = [line for line in text.splitlines()
                           if line.startswith('@') and name in line and 'Tu" = ' in line and 'async_func_pointer' in line]
            if len(descriptors) != 1:
                raise RuntimeError(f'{target}: missing async descriptor for {name}')
            size = re.search(r', i32 (\d+) }>', descriptors[0])
            if not size or int(size[1]) < 2 * bits // 8:
                raise RuntimeError(f'{target}: invalid async context size: {descriptors[0]}')
            context_sizes[name] = int(size[1])
        word = f'i{bits}'
        for name in ['asyncImmediate', 'asyncCaller']:
            if parameters(declarations[name])[1:3] != [word, word]:
                raise RuntimeError(f'{target}: caller-isolation prefix changed for {name}')
        indirect = parameters(declarations['asyncBothIndirect'])
        if 'swiftasync' in indirect[0] or 'sret' in indirect[0] or 'swiftasync' not in indirect[1] or indirect[-1] != 'ptr':
            raise RuntimeError(f'{target}: async indirect result/error parameters changed')
        returns = [line.strip() for line in text.splitlines()
                   if 'musttail call swifttailcc void %' in line and 'swiftself' in line]
        if not any(f'inttoptr ({word} 1 to ptr)' in line for line in returns):
            raise RuntimeError(f'{target}: missing typed-error completion indicator')
        if any('swifterror' in line for line in returns):
            raise RuntimeError(f'{target}: async completion must not use the synchronous error register')
        if not all(name in caller for name in ['swift_task_alloc', 'swift_task_dealloc']):
            raise RuntimeError(f'{target}: missing task-context allocation evidence')
        if 'arm64e' in target and not all(name in text for name in ['llvm.ptrauth.sign', 'llvm.ptrauth.auth']):
            raise RuntimeError(f'{target}: missing authenticated async-context evidence')
        reports.append({'target': target, 'declarations': declarations,
                        'contextSizes': context_sizes, 'errorCompletions': returns[:8]})
    report = {'compiler': run('xcrun', 'swiftc', '--version').strip(),
              'runtimeTested': False, 'targets': reports}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
