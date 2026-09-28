#!/usr/bin/env python3
"""Verify concrete throwing closure carriers and authentication compatibility."""
import json
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swift-throwing-closure-codegen'
    source = '''import ManagedSwiftFixtures
public func plain(_ body: (Bool) -> String, _ flag: Bool) -> String { body(flag) }
public func untyped(_ body: (Bool) throws -> String, _ flag: Bool) throws -> String { try body(flag) }
public func typed(_ body: (Bool) throws(ManagedFailure) -> String, _ flag: Bool) throws(ManagedFailure) -> String { try body(flag) }
public func indirect(_ body: (ErrorLifetimeToken, Bool) throws(LargeFailure) -> ErrorSuccessPayload, _ token: ErrorLifetimeToken, _ flag: Bool) throws(LargeFailure) -> ErrorSuccessPayload { try body(token, flag) }
'''
    reports = []
    for target, sdk_name in [('arm64-apple-macos15.4','macosx'), ('x86_64-apple-macos15.4','macosx'),
                             ('arm64e-apple-ios18.4','iphoneos'), ('arm64_32-apple-watchos11.4','watchos')]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run('xcrun','--sdk',sdk_name,'--show-sdk-path').strip()
        common = ['xcrun','swiftc','-swift-version','6','-parse-as-library','-Onone','-target',target,'-sdk',sdk]
        run(*common,'-enable-library-evolution','-module-name','ManagedSwiftFixtures','-emit-module',
            str(root/'Tests/ManagedSwiftFixtures/Errors.swift'),'-emit-module-path',str(directory/'ManagedSwiftFixtures.swiftmodule'))
        probe = directory/'Probe.swift'
        probe.write_text(source)
        ir_path = directory/'probe.ll'
        run(*common,'-I',str(directory),'-module-name','ClosureErrorProbe',str(probe),'-emit-ir','-o',str(ir_path))
        ir = ir_path.read_text()
        calls = {}
        for name in ['plain','untyped','typed','indirect']:
            body = re.search(r'^define[^\n]*' + str(len(name)) + name + r'[^\n]*\{.*?^}', ir, re.M|re.S)
            if not body: raise RuntimeError(f'{target}: missing {name}')
            candidates = [l.strip() for l in body[0].splitlines() if re.search(r'call swiftcc.* %[^ ]+\(',l) and 'swiftself' in l]
            if len(candidates) != 1: raise RuntimeError(f'{target}: re-evaluate {name}: {candidates}')
            calls[name] = candidates[0]
            if ('swifterror' in calls[name]) != (name != 'plain'):
                raise RuntimeError(f'{target}: incorrect error-register evidence for {name}')
        if 'sret(' not in calls['indirect'] or ', ptr' not in calls['indirect'].split('swifterror',1)[1]:
            raise RuntimeError(f'{target}: missing separate indirect error/result storage')
        if 'arm64e' in target:
            discriminators = [re.search(r'"ptrauth"\(i32 0, i64 (\d+)\)', calls[n]) for n in ['plain','untyped','typed']]
            if not all(discriminators) or len({m[1] for m in discriminators}) != 1:
                raise RuntimeError('Error result must not change the formal closure discriminator')
        reports.append({'target':target,'calls':calls})
    report={'compiler':run('xcrun','swiftc','--version').strip(),'runtimeTested':False,'targets':reports}
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
