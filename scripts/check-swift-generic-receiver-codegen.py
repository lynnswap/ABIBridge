#!/usr/bin/env python3
"""Compare live generic class members with concrete compiler call conventions."""
import json
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / '.build/swift-generic-receiver-codegen'
    output.mkdir(parents=True, exist_ok=True)
    fixture = root / 'Tests/ArchitectureValidation/Sources/SwiftValueFixtures/GenericReceivers.swift'
    source = output / 'Probe.swift'
    source.write_text(fixture.with_name('Errors.swift').read_text() + fixture.read_text() + '''
public final class ConcreteControl {
    @inline(never) public func concrete(_ prefix: String) -> String { prefix }
    public var valueText: String { @inline(never) get { "control" } }
}
''')
    reports = []
    for target, sdk_name in [('arm64-apple-macos15.4', 'macosx'), ('x86_64-apple-macos15.4', 'macosx'),
                             ('arm64e-apple-ios18.4', 'iphoneos'), ('arm64_32-apple-watchos11.4', 'watchos')]:
        directory = output / target
        directory.mkdir(exist_ok=True)
        sdk = run('xcrun', '--sdk', sdk_name, '--show-sdk-path').strip()
        ir = run('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-Onone',
                 '-enable-library-evolution', '-module-name', 'ReceiverProbe', '-target', target,
                 '-sdk', sdk, '-emit-ir', str(source))
        (directory / 'provider.ll').write_text(ir)
        headers = [line for line in ir.splitlines() if line.startswith('define ') and 'swiftcc' in line and '@"' in line]
        symbols = [line.split('@"', 1)[1].split('"', 1)[0] for line in headers]
        names = subprocess.check_output(['xcrun', 'swift-demangle', '--compact'],
                                        input='\n'.join(symbols), text=True).splitlines()
        def header(owner, member):
            prefix = f'ReceiverProbe.{owner}.{member}'
            matches = []
            for line, name in zip(headers, names):
                if name.startswith('(extension in ReceiverProbe):'):
                    name = name.split(':', 1)[1]
                    # These fixture requirements contain only a concrete type or
                    # one protocol; retain the complete name in the IR report.
                    name = re.sub(r'<[^>]*>', '', name, count=1)
                if name.startswith(prefix + '(') or name.startswith(prefix + '<') or name.startswith(prefix + '.getter :'):
                    matches.append(line)
            if len(matches) != 1:
                raise RuntimeError(f'{target}: expected one {owner}.{member}: {matches}')
            return matches[0]
        def parameters(line):
            return re.sub(r'%[\w.]+', '%arg', line.split('"(')[1].rsplit(') #', 1)[0])
        signatures = {}
        for member in ['concrete', 'valueText']:
            generic = header('GenericMemberReceiver', member)
            control = header('ConcreteControl', member)
            if 'swiftself' not in generic or parameters(generic) != parameters(control):
                raise RuntimeError(f'{target}: concrete member needs more than self context: {generic}; {control}')
            signatures[member] = generic
        for member in ['projected', 'echo', 'independent']:
            signatures[member] = header('GenericMemberReceiver', member)
        if 'sret(%swift.opaque)' not in signatures['projected'] or 'sret(%swift.opaque)' not in signatures['echo']:
            raise RuntimeError(f'{target}: dependent values no longer have formal indirect storage')
        if 'ptr %Other' not in signatures['independent']:
            raise RuntimeError(f'{target}: independently generic member metadata convention changed')
        signatures['specialized'] = header('GenericMemberReceiver', 'specialized')
        signatures['specializedText'] = header('GenericMemberReceiver', 'specializedText')
        signatures['witnessText'] = header('GenericMemberReceiver', 'witnessText')
        if parameters(signatures['specialized']) != parameters(signatures['concrete']):
            raise RuntimeError(f'{target}: same-type extension changed its concrete method convention')
        if parameters(signatures['specializedText']) != parameters(signatures['valueText']):
            raise RuntimeError(f'{target}: same-type extension changed its getter convention')
        if 'ptr %Value.CustomStringConvertible' not in signatures['witnessText']:
            raise RuntimeError(f'{target}: additional extension conformance convention changed')
        reports.append({'target': target, 'signatures': signatures})
    report = {'compiler': run('xcrun', 'swiftc', '--version').strip(), 'runtimeTested': False, 'targets': reports}
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"Generic receiver compiler checks passed for {len(reports)} targets: {report['compiler']}")


if __name__ == '__main__':
    main()
