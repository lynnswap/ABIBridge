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
        pack_closures = [line for line in sil.splitlines() if line.startswith('sil ') and any(
            name in line for name in ['closurePackGeneric', 'asyncClosurePackGeneric', 'throwingClosurePackGeneric'])]
        pack_initializers = [line for line in sil.splitlines() if line.startswith('sil ')
                             and 'GenericClosurePackOwnerC' in line and 'cfC :' in line]
        if len(pack_closures) != 3 or not all('@pack_guaranteed Pack{repeat' in line and '@substituted' in line and '@out ' in line
                                             for line in pack_closures):
            raise RuntimeError(f'{target}: closure pack borrowing or element reabstraction changed: {pack_closures}')
        if len(pack_initializers) != 1 or '@pack_owned Pack{repeat' not in pack_initializers[0]:
            raise RuntimeError(f'{target}: closure pack initializer ownership changed: {pack_initializers}')
        runtime_values = {}
        for name, convention in {
            'borrowRuntimeValue': '(@in_guaranteed T) -> Int64',
            'moveRuntimeValue': '(@in T) -> @out T',
            'consumeRuntimeValueAndThrow': '(@in T) -> @error any Error',
            'replaceRuntimeValue': '(@inout T, @in T) -> ()',
            'moveRuntimeValueAfterArgument': '(@in T, Int64) -> @out T',
            'borrowRuntimeValueAsync': '(@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, @in_guaranteed T, @guaranteed AsyncGate) -> Int64',
            'moveRuntimeValueAsync': '(@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, @in T) -> @out T',
        }.items():
            # The length-prefixed identifier excludes names extending this one.
            identifier = str(len(name)) + name
            candidates = [line for line in sil.splitlines() if line.startswith('sil [noinline]') and identifier in line]
            if len(candidates) != 1 or '<T where T : ~Copyable>' not in candidates[0] or convention not in candidates[0]:
                raise RuntimeError(f'{target}: runtime value ownership changed for {name}: {candidates}')
            runtime_values[name] = candidates[0]
        consuming_callbacks = {}
        for name, convention in {
            'visitConsumingRuntimeValue': '(@in τ_0_0) -> (Int64, @error any Error)',
            'visitNonthrowingConsumingRuntimeValue': '(@in τ_0_0) -> Int64',
            'makeRuntimeConsumer': '(@in τ_0_0) -> Int64',
            'visitConsumingRuntimeValueAsync': '@guaranteed Builtin.ImplicitActor, @in τ_0_0) -> (Int64, @error any Error)',
            'visitConsumingString': '(@owned String) -> Int64',
        }.items():
            identifier = str(len(name)) + name
            candidates = [line for line in sil.splitlines() if line.startswith('sil [noinline]') and identifier in line]
            if len(candidates) != 1 or convention not in candidates[0]:
                raise RuntimeError(f'{target}: consuming callback ownership changed for {name}: {candidates}')
            consuming_callbacks[name] = candidates[0]
        inout_callbacks = {}
        for name, convention in {
            'visitRuntimeInout': '(@inout τ_0_0) -> @error any Error',
            'visitRuntimeInoutAsync': '@guaranteed Builtin.ImplicitActor, @inout τ_0_0) -> @error any Error',
            'makeRuntimeSwap': '(@inout τ_0_0, @inout τ_0_1) -> ()',
            'visitStringInout': '(@inout String) -> ()',
        }.items():
            identifier = str(len(name)) + name
            candidates = [line for line in sil.splitlines() if line.startswith('sil [noinline]') and identifier in line]
            if len(candidates) != 1 or convention not in candidates[0]:
                raise RuntimeError(f'{target}: inout callback ownership changed for {name}: {candidates}')
            inout_callbacks[name] = candidates[0]
        reports.append({'target':target, 'signatures':signatures, 'initializers':initializers, 'ownedGenericClosures':owned_closures,
                        'closurePacks':pack_closures, 'closurePackInitializers':pack_initializers, 'runtimeValues':runtime_values, 'consumingCallbacks':consuming_callbacks, 'inoutCallbacks':inout_callbacks})
    report = {'compiler':run('xcrun','swiftc','--version').strip(), 'runtimeTested':False, 'targets':reports}
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__ == '__main__': main()
