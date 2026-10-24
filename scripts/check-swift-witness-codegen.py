#!/usr/bin/env python3
"""Verify requirement slots and sync/async witness authentication in compiler IR."""
import json
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ROOT = REPO / '.build/swift-witness-codegen'
SOURCE = REPO / 'Tests/ArchitectureValidation/CompilerProbes/WitnessDispatch'
ROOT.mkdir(parents=True, exist_ok=True)
def run(*arguments):
    return subprocess.check_output(arguments, text=True)

version = run('xcrun', 'swiftc', '--version').strip()
report = {'toolchain': version, 'runs': []}
for target, sdk_name in [('arm64-apple-macos15.4', 'macosx'),
                         ('arm64e-apple-ios18.4', 'iphoneos'),
                         ('arm64_32-apple-watchos11.4', 'watchos')]:
    sdk = run('xcrun', '--sdk', sdk_name, '--show-sdk-path').strip()
    for evolution in [False, True]:
        directory = ROOT / target / ('evolution' if evolution else 'non-evolution')
        directory.mkdir(parents=True, exist_ok=True)
        common = ['xcrun', 'swiftc', '-swift-version', '6', '-enable-upcoming-feature',
                  'ApproachableConcurrency', '-enable-upcoming-feature',
                  'NonisolatedNonsendingByDefault', '-parse-as-library', '-Onone',
                  '-target', target, '-sdk', sdk]
        provider = common + (['-enable-library-evolution'] if evolution else []) + [
            '-module-name', 'WitnessProbe', str(SOURCE / 'Provider.swift')]
        run(*provider, '-emit-module', '-emit-module-path', str(directory / 'WitnessProbe.swiftmodule'))
        run(*provider, '-emit-ir', '-o', str(directory / 'provider.ll'))
        run(*common, '-module-name', 'WitnessCaller', '-I', str(directory),
            str(SOURCE / 'Caller.swift'), '-emit-ir', '-o', str(directory / 'caller.ll'))
        report['runs'].append({'xcode': version, 'target': target, 'library_evolution': evolution,
                               'directory': str(directory.relative_to(ROOT))})
(ROOT / 'run-report.json').write_text(json.dumps(report, indent=2) + '\n')

NAMES = ['associatedtype', 'initializer', 'sync', 'getter', 'setter', 'modify', 'static', 'async', 'echo']
KINDS = [7, 2, 1, 3, 4, 6, 1, 1, 1]
FLAGS = [7, 2, 17, 19, 20, 22, 1, 49, 17]
EXPECTED_DISC = [46705, 3737, 26543, 38572, 7018, 538, 59518, 19184, 39857]
CALLERS = {'initializer': 'callInit', 'sync': 'callSync', 'getter': 'callGet', 'setter': 'callSet', 'static': 'callCode', 'async': 'callAsync', 'echo': 'callEcho'}
THUNKS = {'initializer': '4seed', 'sync': '4sync', 'getter': '5value.*vg', 'setter': '5value.*vs', 'static': '4code', 'async': '12asynchronous', 'echo': '4echo'}

def require(value, reason):
    if not value: raise RuntimeError(reason)

def function(ir, marker):
    found = re.search(r'^define [^\n]*' + marker + r'[^\n]*\{.*?^}', ir, re.M | re.S)
    require(found, f'Missing function: {marker}')
    return found[0]

reports = []
for run in json.loads((ROOT/'run-report.json').read_text())['runs']:
    directory = ROOT / run['directory']
    provider, caller = [(directory/name).read_text() for name in ['provider.ll', 'caller.ll']]
    pac = run['target'].startswith('arm64e-')
    word = 4 if run['target'].startswith('arm64_32-') else 8
    proto = next(line for line in provider.splitlines() if line.startswith('@"$s12WitnessProbe0B0Mp" ='))
    flags = [int(value) & 0xffffffff for value in re.findall(r'%swift.protocol_requirement \{ i32 (-?\d+), i32 0 \}', proto)]
    require([value & 0x3f for value in flags] == FLAGS, 'Requirement kinds, instance and async flags changed')
    require([value >> 16 for value in flags] == (EXPECTED_DISC if pac else [0]*9), 'Unexpected declaration discriminator')
    aliases = [line for line in provider.splitlines() if 'Tq" = alias %swift.protocol_requirement' in line]
    require(len(aliases) == (8 if run['library_evolution'] else 0), 'Tq evidence does not match library evolution mode')
    if aliases:
        require([int(re.search(r'i32 (\d+)\)$', line)[1]) for line in aliases] == list(range(7,15)), 'Tq array aliases changed')
    tables = [line for line in provider.splitlines() if re.match(r'^@"[^\"]+(?:WP|Wp)" = (?:internal )?global \[10 x ptr\]', line)]
    require(len(tables) == 3, 'Expected Plain table, Box pattern and Conditional pattern')
    table_rows = []
    for table in tables:
        symbol = re.match(r'^@"([^\"]+)"', table)[1]
        contents = table.split('[10 x ptr] [',1)[1].rsplit('], align',1)[0]
        entries = re.findall(r'ptr @"([^\"]+)"', contents)
        require(len(entries) == 10, 'All descriptor and requirement entries must remain counted')
        if pac:
            descriptor = next(line for line in provider.splitlines() if line.startswith('@"'+entries[0]+'" ='))
            require(f'i32 2, i64 ptrtoint (ptr @"{symbol}" to i64), i64 50923' in descriptor,
                    'Conformance descriptor must use data key A, table address and 0xc6eb')
        for index in range(1,10):
            if pac:
                auth = next(line for line in provider.splitlines() if line.startswith('@"'+entries[index]+'" ='))
                match = re.search(r', i32 ([0-3]), i64 (.*), i64 (\d+) \}, section "llvm.ptrauth"', auth)
                require(match, 'Missing signed pointer record')
                key, address, discriminator = int(match[1]), match[2], int(match[3])
                expected_key = 2 if index in [1,8] else 0
                require(key == expected_key, f'Wrong signing key at slot {index}')
                require(discriminator == flags[index-1] >> 16, 'Slot discriminator differs from requirement flags')
                require(f'ptr @"{symbol}", i32 0, i32 {index})' in address, 'Signing must blend the actual slot address')
            elif index == 8:
                require(entries[index].endswith('TWTu'), 'Async slot must contain an async descriptor, not code')
        table_rows.append({'table':symbol, 'entries':entries})
    calls = {}
    for role, marker in CALLERS.items():
        slot = NAMES.index(role) + 1
        if run['library_evolution']:
            code = function(provider, r'0B0P' + THUNKS[role] + r'[^\"]*Tj"\(')
        else:
            code = function(caller, marker + r'[^\"]*"\(')
        access = re.search(r'(%[\w.]+) = getelementptr inbounds ptr, ptr %[^,\n]+, i32 ' + str(slot) + r'\n', code)
        require(access, f'{role} does not read slot {slot}')
        if pac:
            slot_int = re.search(r'(%[\w.]+) = ptrtoint ptr '+re.escape(access[1])+r' to i64',code)
            require(slot_int, 'Slot address not used as pointer-auth storage address')
            blend = re.search(r'(%[\w.]+) = call i64 @llvm.ptrauth.blend\(i64 '+re.escape(slot_int[1])+r', i64 '+str(flags[slot-1]>>16)+r'\)',code)
            require(blend, 'Slot does not blend its address with the descriptor discriminator')
            require(f'"ptrauth"(i32 0, i64 {blend[1]})' in code, 'Witness code call must authenticate with instruction key A')
            if role == 'async':
                require(re.search(r'@llvm.ptrauth.resign.load.relative\(i64 %[^,]+, i32 2, i64 '+re.escape(blend[1])+r', i32 0, i64 '+re.escape(blend[1])+r', i64 0\)',code), 'Async entry must authenticate data then re-sign relative code')
                require(re.search(r'@llvm.ptrauth.auth\(i64 %[^,]+, i32 2, i64 '+re.escape(blend[1])+r'\)',code), 'Async context size must come from authenticated data descriptor')
        else:
            require('llvm.ptrauth' not in code, 'Unsigned target unexpectedly authenticates a protocol witness')
        if role == 'async':
            require('swift.async_func_pointer' in code and 'load i32' in code, 'Missing async descriptor context size read')
        calls[role] = {'slot':slot, 'byte_offset':word*slot, 'declaration_discriminator':flags[slot-1]>>16,
                       'function_header':code.splitlines()[0],
                       'evidence':[line.strip() for line in code.splitlines() if any(token in line for token in ['getelementptr inbounds ptr','ptrauth.blend','ptrauth.resign.load.relative','ptrauth.auth','"ptrauth"(','swift.async_func_pointer'])]}
    conformances = []
    for owner in ['3Box','11Conditional']:
        line = next(line for line in provider.splitlines() if re.match(r'^@"\$s12WitnessProbe'+owner+r'[^\"]+Mc" =',line))
        count = re.search(r'i32 (131\d+),.*?i16 10, i16 (\d+), i32 0,',line)
        require(count,'Generic conformance must carry instantiation metadata')
        flags_value, private = map(int,count.groups())
        require(flags_value & (1<<17), 'Missing generic witness table flag')
        conformances.append({'owner':owner, 'conformance_flags':flags_value, 'table_words':10,'requires_instantiation_bit':private&1,'private_words':private>>1})
    conditional = function(caller,'getConditionalTable')
    require('@swift_getWitnessTable(' in conditional,'Conditional conformance must obtain its instantiated table through runtime')
    result = {key:run[key] for key in ['xcode','target','library_evolution','directory']}
    result.update({'word_size':word,'pointer_authentication':pac,'requirements':[{'slot':i+1,'name':name,'flags':flags[i],'kind':flags[i]&15,'discriminator':flags[i]>>16} for i,name in enumerate(NAMES)],'tables':table_rows,'calls':calls,'generic_conformances':conformances})
    reports.append(result)
    print(f"PASS check {run['xcode']} {run['target']} evolution={run['library_evolution']}")
(ROOT/'evidence.json').write_text(json.dumps(reports,indent=2)+'\n')
print(f'Checked {len(reports)} compiler variants, {len(reports)*len(CALLERS)} dispatch paths, {len(reports)*3} tables/patterns.')
