#!/usr/bin/env python3
"""Verify async closure descriptors, hidden isolation, and stored body lowering."""
import json
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swift-async-closure-codegen'
    source = '''
@frozen public struct SmallError: Error { public let value: Int64 }
@frozen public struct LargeError: Error { public let a, b, c, d, e: Int64 }
@frozen public struct LargeValue { public let a, b, c, d, e: Int64 }
public func direct(_ body: @concurrent (Int64) async -> Int64, _ value: Int64) async -> Int64 { await body(value) }
public nonisolated(nonsending) func caller(_ body: nonisolated(nonsending) (Int64) async -> Int64, _ value: Int64) async -> Int64 { await body(value) }
public func typed(_ body: @concurrent (Bool) async throws(SmallError) -> Int64, _ flag: Bool) async throws(SmallError) -> Int64 { try await body(flag) }
public func indirect(_ body: @concurrent (Bool) async throws(LargeError) -> LargeValue, _ flag: Bool) async throws(LargeError) -> LargeValue { try await body(flag) }
public typealias StoredBody = (nonisolated(nonsending) @Sendable () async -> Void)
public func storage(_ body: @escaping StoredBody, _ observer: @convention(c) (UnsafeRawPointer) -> Void) {
    withUnsafePointer(to: body) { observer(UnsafeRawPointer($0)) }
}
public typealias ConcurrentBody = @Sendable @concurrent () async -> Void
public func concurrentStorage(_ body: @escaping ConcurrentBody, _ observer: @convention(c) (UnsafeRawPointer) -> Void) {
    withUnsafePointer(to: body) { observer(UnsafeRawPointer($0)) }
}
'''
    reports = []
    for target, sdk_name in [('arm64-apple-macos15.4','macosx'), ('x86_64-apple-macos15.4','macosx'),
                             ('arm64e-apple-ios18.4','iphoneos'), ('arm64_32-apple-watchos11.4','watchos')]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        probe = directory / 'Probe.swift'
        probe.write_text(source)
        sdk = run('xcrun','--sdk',sdk_name,'--show-sdk-path').strip()
        ir_path = directory / 'probe.ll'
        run('xcrun','swiftc','-swift-version','6','-parse-as-library','-Onone',
            '-enable-upcoming-feature','ApproachableConcurrency', '-target',target,'-sdk',sdk,
            '-module-name','AsyncClosureProbe',str(probe),'-emit-ir','-o',str(ir_path))
        ir = ir_path.read_text()
        calls = {}
        for name, count in [('direct',3), ('caller',5), ('typed',3), ('indirect',5)]:
            body = re.search(r'^define[^\n]*' + str(len(name)) + name + r'[^\n]*\{.*?^}', ir, re.M|re.S)
            if not body: raise RuntimeError(f'{target}: missing {name}')
            candidates = [line.strip() for line in body[0].splitlines()
                          if 'musttail call swifttailcc void %' in line and 'swiftself' in line]
            if len(candidates) != 1: raise RuntimeError(f'{target}: re-evaluate {name}: {candidates}')
            call = candidates[0]
            arguments = call.split(' #',1)[0].split('(',1)[1].rsplit(')',1)[0].split(', ')
            if len(arguments) != count or not any('swiftasync' in arg for arg in arguments):
                raise RuntimeError(f'{target}: incorrect async closure arguments: {call}')
            if name == 'indirect' and ('swiftasync' in arguments[0] or 'swiftasync' not in arguments[1]):
                raise RuntimeError(f'{target}: indirect async output must be an ordinary leading argument')
            calls[name] = call
            if 'arm64e' in target:
                auth = re.search(r'"ptrauth"\(i32 0, i64 (\d+)\)', call)
                if not auth or f'i32 2, i64 {auth[1]}' not in body[0]:
                    raise RuntimeError(f'{target}: descriptor data-key and entry code-key contract changed')
        if 'arm64e' in target:
            if 'i64 21761)' not in calls['direct'] or 'i64 51173)' not in calls['caller']:
                raise RuntimeError('Re-evaluate the formal opaque-isolation parameter discriminator')
            if not re.search(r'TRTATu[^\n]*i32 2, i64 0, i64 51264', ir):
                raise RuntimeError('Stored caller-isolated Void bodies require their generic indirect-result discriminator')
            if not re.search(r'TRTATu[^\n]*i32 2, i64 0, i64 29199', ir):
                raise RuntimeError('Stored concurrent Void bodies require their distinct generic discriminator')
        stored_entries = [line for line in ir.splitlines() if line.startswith('define') and 'TRTA"(' in line]
        if not any('ptr noalias' in line and 'swiftasync' in line and 'swiftself' in line for line in stored_entries):
            raise RuntimeError(f'{target}: stored async body lost its indirect empty result')
        reports.append({'target':target, 'calls':calls, 'storedBodyEntries':stored_entries})
    report = {'compiler':run('xcrun','swiftc','--version').strip(), 'runtimeTested':False, 'targets':reports}
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__ == '__main__': main()
