#!/usr/bin/env python3
"""Verify explicit Swift ownership and initializer defaults with the compiler."""
import json
from pathlib import Path
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swift-argument-codegen'
    reports = []
    for target, sdk_name in [('arm64-apple-macos15.4','macosx'), ('x86_64-apple-macos15.4','macosx'),
                             ('arm64e-apple-ios18.4','iphoneos'), ('arm64_32-apple-watchos11.4','watchos')]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run('xcrun','--sdk',sdk_name,'--show-sdk-path').strip()
        sil = run('xcrun','swiftc','-swift-version','6','-parse-as-library','-enable-library-evolution',
                  '-module-name','ManagedSwiftFixtures','-target',target,'-sdk',sdk,'-emit-silgen',
                  *[str(root/'Tests/ManagedSwiftFixtures'/name) for name in [
                      'Errors.swift','Async.swift','ParameterConventions.swift','GenericCalls.swift',
                      'RuntimeValues.swift','Values.swift','ExplicitValues.swift']])
        (directory/'provider.sil').write_text(sil)
        signatures = {}
        for name, expected in {
            'mutateArguments': '(@inout String, @inout Array<String>, @inout Int64, Bool)',
            'consumeArguments': '(@owned String, @guaranteed String, @owned ArgumentToken, Bool)',
            'consumeLargeArgument': '(@owned ErrorSuccessPayload, @guaranteed ArgumentCounts, Bool)',
            'asyncArguments': '(@guaranteed AsyncGate, @inout String, @owned String, @guaranteed String, Bool)',
            'borrowingGeneric': '(@in_guaranteed Value)',
            'consumingGeneric': '(@in Value)',
            'mutateGeneric': '(@inout Value, @in Value, @in_guaranteed Failure, Bool)',
            'suspendedMutateGeneric': '(@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, @inout Value, @in Value, @in_guaranteed Failure, Bool)',
        }.items():
            candidates = [line for line in sil.splitlines() if line.startswith('sil [noinline]') and name in line]
            if len(candidates) != 1 or expected not in candidates[0]:
                raise RuntimeError(f'{target}: re-evaluate {name}: {candidates}')
            signatures[name] = candidates[0]
        initializers = [line for line in sil.splitlines() if line.startswith('sil ') and 'ArgumentOwnerC' in line and 'cfC :' in line]
        if len(initializers) != 2 or not all('(@guaranteed String, @owned String, @guaranteed ArgumentToken,' in line for line in initializers):
            raise RuntimeError(f'{target}: mixed initializer ownership changed: {initializers}')
        if not any('@async' in line and '@owned AsyncGate' in line for line in initializers):
            raise RuntimeError(f'{target}: ordinary initializer arguments must retain owned convention')
        owned_closures = [line for line in sil.splitlines() if line.startswith('sil ') and (
            'consumeClosureGeneric' in line or 'consumeClosureThenArgumentGeneric' in line
            or ('GenericClosureOwnerC' in line and ('cfC :' in line or '4bodyxycvs :' in line)))]
        if len(owned_closures) != 4 or not all('(@owned @callee_guaranteed @substituted' in line for line in owned_closures):
            raise RuntimeError(f'{target}: generic closure initializer/setter/consuming ownership changed: {owned_closures}')
        reports.append({'target':target, 'signatures':signatures, 'initializers':initializers, 'ownedGenericClosures':owned_closures})
    report = {'compiler':run('xcrun','swiftc','--version').strip(), 'runtimeTested':False, 'targets':reports}
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__ == '__main__': main()
