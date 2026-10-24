#!/usr/bin/env python3
"""Check the product shape rule against each registered SDK requirement's
own compiler-imported Swift declaration, plus Swift @objc fixtures.

The names are build-time evidence only; no SDK table ships with the product.
Pass --collected and --runtime to reuse an existing measured SDK dataset.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'Tests/ArchitectureValidation/CompilerProbes/ObjectiveCRequirements'
USR = re.compile(r'^c:(?:@M@\w+@)?objc\(pl\)([A-Za-z0-9_]+)\((im|cm|py|cpy)\)(.+)$')
ALIASES = {'TimeInterval': 'Double', 'unichar': 'UInt16', 'UniChar': 'UInt16',
           'OSStatus': 'Int32', 'CFIndex': 'Int', 'NSInteger': 'Int', 'NSUInteger': 'UInt', '()': 'Void'}
PINNED = {'Int8', 'UInt8', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64',
          'Int', 'UInt', 'Bool', 'Float', 'Double', 'Void', 'AnyObject'}


def run(command, **kwargs):
    result = subprocess.run([str(x) for x in command], text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(' '.join(map(str, command)) + '\n' + result.stdout + result.stderr)
    return result.stdout


def fragment(parts):
    return ''.join(p['spelling'] for p in parts or [])


def collect(paths):
    protocols = {}
    seen = set()
    for path in paths:
        graph = json.loads(path.read_text())
        for symbol in graph['symbols']:
            match = USR.match(symbol['identifier']['precise'])
            if not match:
                continue
            protocol, side, selector = match.groups()
            declaration = fragment(symbol.get('declarationFragments'))
            key = (symbol['identifier']['precise'], declaration)
            if key in seen:
                continue
            seen.add(key)
            signature = symbol.get('functionSignature', {})
            protocols.setdefault(protocol, []).append({
                'sel': selector, 'selkind': side, 'kind': symbol['kind']['identifier'],
                'decl': declaration,
                'params': [fragment(p.get('declarationFragments')) for p in signature.get('parameters', [])],
                'returns': fragment(signature.get('returns')),
                'unavailable': any(a.get('isUnconditionallyUnavailable') and a.get('domain') in (None, '*', 'Swift', 'macOS')
                                   for a in symbol.get('availability', [])),
            })
    return {'protocols': protocols}


def host(text):
    text = text.strip()
    text = re.sub(r'^(inout|__owned|borrowing|consuming|sending)\s+', '', text)
    text = re.sub(r'\s*=.*$', '', text).removeprefix('Swift.')
    text = ALIASES.get(text, text)
    return text if text in PINNED else '*'


def request(entry):
    declaration, kind = entry['decl'], entry['kind']
    role = ('initializer' if kind == 'swift.init' else 'subscript' if 'subscript' in kind
            else 'getter' if 'property' in kind else 'method')
    result = entry.get('returns') or 'Void'
    if role == 'getter':
        match = re.search(r'var\s+\w+\s*:\s*(.+?)\s*\{', declaration)
        result = match[1] if match else '*'
    return {'role': role, 'static': bool(re.search(r'\b(static|class) (func|var|subscript)', declaration)) or kind.startswith('swift.type.'),
            'async': bool(re.search(r'\basync\b', declaration)), 'result': host(result),
            'parameters': [host(p.split(':', 1)[-1]) for p in entry['params']], 'declaration': declaration}


def cases(collected, runtime):
    protocols = {p['name']: p for p in runtime}
    result = []
    accessor_methods = dropped_parameters = 0
    for name, entries in collected['protocols'].items():
        proto = protocols.get(name)
        if not proto:
            continue
        properties = {(p['name'], p['instance']): p for p in proto['properties']}
        accessors = set()
        for prop in proto['properties']:
            attrs = prop['attributes'].split(',')
            getter = next((a[1:] for a in attrs if a.startswith('G')), prop['name'])
            accessors.add((getter, prop['instance']))
            if 'R' not in attrs:
                accessors.add((next((a[1:] for a in attrs if a.startswith('S')), 'set' + prop['name'][0].upper() + prop['name'][1:] + ':'), prop['instance']))
        for entry in entries:
            if entry['unavailable']:
                continue
            req = request(entry)
            selector, side = entry['sel'], entry['selkind']
            instance = side in ('im', 'py')
            if side in ('py', 'cpy'):
                prop = properties.get((selector, instance))
                if not prop:
                    continue
                attrs = prop['attributes'].split(',')
                result.append(dict(req, instance=instance, selector=selector, readonly='R' in attrs,
                                   encoding=next((a[1:] for a in attrs if a.startswith('T')), '?')))
            else:
                methods = [m for m in proto['methods'] if m['sel'] == selector and m['instance'] == instance]
                if not methods:
                    continue
                # Each selector has one encoding per protocol/side. Duplicate
                # declarations from module reexports do not change the check.
                method = methods[0]
                result.append(dict(req, instance=instance, selector=selector, encoding=method['types']))
                if req['role'] == 'method' and (selector, instance) in accessors:
                    accessor_methods += 1
                if len(req['parameters']) != selector.count(':'):
                    dropped_parameters += 1
    return result, accessor_methods, dropped_parameters


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--collected', type=Path)
    parser.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
    toolchain = run(['xcrun', 'swiftc', '--version']) + sdk
    build = ROOT / '.build/objc-requirement-shape' / hashlib.sha256(toolchain.encode()).hexdigest()[:12]
    build.mkdir(parents=True, exist_ok=True)
    if args.collected and args.runtime:
        collected = json.loads(args.collected.read_text())
        runtime = json.loads(args.runtime.read_text())
    else:
        sdk_frameworks = Path(sdk) / 'System/Library/Frameworks'
        headers = subprocess.run(['rg', '-l', '@protocol', str(sdk_frameworks), '-g', '*.h'], text=True, capture_output=True, check=True).stdout.splitlines()
        modules = sorted({'ObjectiveC'} | {Path(p).relative_to(sdk_frameworks).parts[0].split('.')[0] for p in headers})
        modules = [m for m in modules if m == 'ObjectiveC' or (
            (sdk_frameworks / (m + '.framework/Modules/module.modulemap')).exists()
            and not re.search(r'requires\s+!swift', (sdk_frameworks / (m + '.framework/Modules/module.modulemap')).read_text()))]
        graph_root = build / 'sdk'
        graph_root.mkdir(exist_ok=True)
        def extract(module):
            directory = graph_root / module
            directory.mkdir(exist_ok=True)
            if not list(directory.glob('*.symbols.json')):
                run(['xcrun', 'swift-symbolgraph-extract', '-module-name', module, '-sdk', sdk,
                     '-target', 'arm64-apple-macos15.4', '-minimum-access-level', 'private', '-output-dir', directory])
            return list(directory.glob('*.symbols.json'))
        with ThreadPoolExecutor(max_workers=2) as pool:
            graphs = [p for paths in pool.map(extract, modules) for p in paths]
        collected = collect(graphs)
        run(['xcrun', 'swiftc', FIXTURES / 'Records.swift', '-o', build / 'records'])
        runtime = json.loads(run([build / 'records'] + modules))
    sdk_cases, accessors, drops = cases(collected, runtime)
    if not sdk_cases or not accessors or not drops:
        raise RuntimeError('SDK evidence must cover requirements, property accessor methods, and dropped error/completion parameters')
    # Compiler-generated Swift @objc records exercise renaming, static members,
    # initializers, async/throwing imports, scalars, blocks, structs and pointers.
    module = 'ObjectiveCRequirementFixtures'
    run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos15.4', '-emit-library', '-emit-module', '-module-name', module,
         FIXTURES / 'Provider.swift', '-o', build / ('lib' + module + '.dylib'),
         '-emit-module-path', build / (module + '.swiftmodule')])
    graphs = build / 'fixture-graphs'
    graphs.mkdir(exist_ok=True)
    run(['xcrun', 'swift-symbolgraph-extract', '-module-name', module, '-sdk', sdk,
         '-target', 'arm64-apple-macos15.4', '-I', build, '-minimum-access-level', 'private', '-output-dir', graphs])
    run(['xcrun', 'swiftc', FIXTURES / 'Records.swift', '-o', build / 'records'])
    fixture_runtime = json.loads(run([build / 'records', build / ('lib' + module + '.dylib')]))
    fixture_cases, _, _ = cases(collect(graphs.glob('*.symbols.json')), fixture_runtime)
    legacy = FIXTURES / 'Legacy'
    legacy_library = build / 'libLegacy.dylib'
    run(['xcrun', 'clang', '-fobjc-arc', '-dynamiclib', '-isysroot', sdk,
         '-I', legacy, legacy / 'Legacy.m', '-framework', 'Foundation', '-o', legacy_library])
    legacy_graphs = build / 'legacy-graphs'
    legacy_graphs.mkdir(exist_ok=True)
    run(['xcrun', 'swift-symbolgraph-extract', '-module-name', 'Legacy', '-sdk', sdk,
         '-target', 'arm64-apple-macos15.4', '-I', legacy, '-minimum-access-level', 'private', '-output-dir', legacy_graphs])
    legacy_runtime = json.loads(run([build / 'records', legacy_library]))
    legacy_cases, _, _ = cases(collect(legacy_graphs.glob('*.symbols.json')), legacy_runtime)
    if not legacy_cases:
        raise RuntimeError('The Clang fixture supplied no checked requirements')
    # Swift @objc protocol names include their module in the runtime.
    if not fixture_cases:
        fixture_runtime = [dict(p, name=p['name'].split('.')[-1]) for p in fixture_runtime]
        fixture_cases, _, _ = cases(collect(graphs.glob('*.symbols.json')), fixture_runtime)
    if not fixture_cases:
        raise RuntimeError('The compiled Swift fixture supplied no checked requirements')
    records = build / 'cases.json'
    records.write_text(json.dumps(sdk_cases + fixture_cases + legacy_cases))
    run(['xcrun', 'swiftc', ROOT / 'Sources/ABIBridge/SwiftObjectiveCMemberShape.swift', FIXTURES / 'Check.swift', '-o', build / 'check'])
    print(run([build / 'check', records]).strip())
    print(f'SDK clauses exercised: {accessors} accessor methods, {drops} declarations dropping error/completion parameters; {len(fixture_cases) + len(legacy_cases)} fixture declarations')


if __name__ == '__main__':
    main()
