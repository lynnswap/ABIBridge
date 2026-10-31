#!/usr/bin/env python3
"""Verify witness ABI, ownership and dynamic registration authentication in compiler IR."""
import argparse
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
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--include-arm64e-x1', action='store_true',
                    help='Also check the Xcode 27 arm64e.x1 ABI')
arguments = parser.parse_args()
targets = [('arm64-apple-macos15.4', 'macosx'),
           ('arm64e-apple-ios18.4', 'iphoneos'),
           ('arm64_32-apple-watchos11.4', 'watchos')]
if arguments.include_arm64e_x1:
    targets.append(('arm64e.x1-apple-ios18.4', 'iphoneos'))
for target, sdk_name in targets:
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
        run(*provider, '-emit-silgen', '-o', str(directory / 'provider.sil'))
        run(*common, '-module-name', 'WitnessCaller', '-I', str(directory),
            str(SOURCE / 'Caller.swift'), '-emit-ir', '-o', str(directory / 'caller.ll'))
        run('xcrun', 'clang++', '-std=c++20', '-O0', '-target', target,
            '-isysroot', sdk, '-I', str(REPO / 'Sources/ABIBridgeCore/include'),
            '-emit-llvm', '-S', str(REPO / 'Sources/ABIBridgeCore/SwiftProtocolConformance.cpp'),
            '-o', str(directory / 'registration.ll'))
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

def check_delegate(provider, caller, sil, registration, pac, narrow, evolution):
    """Compare native class witnesses and the actual dynamic registration code."""
    expected = {'receive': ['i32', 'i32', 'i32', 'ptr', 'i64'] if narrow else ['i64', 'ptr', 'ptr', 'i64'],
                'consume': ['i32', 'i32', 'i32', 'ptr'] if narrow else ['i64', 'ptr', 'ptr'],
                'accept': ['ptr'],
                'fail': ['i32', 'i32', 'i32'] if narrow else ['i64', 'ptr'],
                'typedFail': ['i32', 'i32', 'i32'] if narrow else ['i64', 'ptr'],
                'finish': ['i1']}
    ownership = {'receive': '(@guaranteed String, @guaranteed DelegateToken, Int64, @guaranteed DelegateObject)',
                 'consume': '(@owned String, @owned DelegateToken, @guaranteed DelegateObject)',
                 'accept': '(@guaranteed DelegateObject, @guaranteed DelegateObject)',
                 'fail': '(@guaranteed String, @guaranteed DelegateObject) -> @error any Error',
                 'typedFail': '(@guaranteed String, @guaranteed DelegateObject) -> @error DelegateFailure',
                 'finish': '(Bool, @owned DelegateObject) -> @error any Error'}
    if evolution:
        ownership['typedFail'] = ownership['typedFail'].replace('@error ', '@error_indirect ')
    callers = {'receive': '12callDelegate', 'consume': '19callConsumeDelegate',
               'accept': '16callSelfDelegate', 'fail': '20callThrowingDelegate',
               'typedFail': '25callTypedThrowingDelegate', 'finish': '18callFinishDelegate'}
    protocol = next(line for line in provider.splitlines() if line.startswith('@"$s12WitnessProbe8DelegateMp" ='))
    flags = [int(value) & 0xffffffff for value in re.findall(r'%swift.protocol_requirement \{ i32 (-?\d+), i32 0 \}', protocol)]
    require(len(flags) == len(expected) and all(value & 0x3f == 17 for value in flags),
            'Class-bound callbacks must be synchronous instance methods')
    results = {}
    for index, method in enumerate(expected):
        identifier = str(len(method)) + method
        witness = function(provider, r'14DelegateObjectC[^\"]*' + identifier + r'[^\"]*TW"\(')
        header = witness.splitlines()[0]
        parameters = re.search(r'"\((.*), ptr swiftself %\w+(.*), ptr %Self, ptr %SelfWitnessTable\)', header)
        require(parameters and [part.split()[0] for part in parameters[1].split(', ')] == expected[method],
                f'{method}: class-bound witness must pass direct Self separately from arguments and trailing metadata')
        extras = parameters[2].split(', ')[1:]
        throws = method in ['fail', 'typedFail', 'finish']
        require(any('swifterror' in part for part in extras) == throws,
                f'{method}: witness throwing convention must use the Swift error register')
        require(len(extras) == int(throws) + int(method == 'typedFail' and evolution),
                f'{method}: resilient typed errors require one ordinary output pointer before witness metadata')
        entry = next(line for line in sil.splitlines() if line.startswith('sil ') and identifier in line and 'FTW :' in line)
        require('@convention(witness_method: Delegate)' in entry and ownership[method] in entry,
                f'{method}: formal witness argument ownership changed')
        call = function(caller, callers[method])
        require(re.search(r'call swiftcc .*ptr swiftself %0, .*ptr %[^,]+, ptr %[^,]+\)', call),
                f'{method}: provider must receive direct object Self plus metadata and witness table')
        if pac:
            name = re.search(r'@"([^\"]+)"\(', header)[1]
            auth = next(line for line in provider.splitlines() if line.startswith('@"'+name+'.ptrauth" ='))
            require(f'i32 0, i64 ptrtoint (ptr getelementptr inbounds ([{len(expected)+1} x ptr]' in auth
                    and f'i32 0, i32 {index+1}) to i64), i64 {flags[index] >> 16}' in auth,
                    f'{method}: native witness signing must use the actual slot and requirement discriminator')
        results[method] = {'signature': header, 'ownership': entry, 'discriminator': flags[index] >> 16}
    core = function(registration, 'ABICreateSwiftProtocolConformance')
    if pac:
        for discriminator in [0xae86, 0xc6eb]:
            blend = re.search(r'(%[\w.]+) = call i64 @llvm.ptrauth.blend\(i64 %[^,]+, i64 '+str(discriminator)+r'\)', core)
            require(blend and re.search(r'@llvm.ptrauth.sign\(i64 %[^,]+, i32 2, i64 '+re.escape(blend[1])+r'\)', core),
                    f'Dynamic registration must sign its protocol/descriptor storage with {discriminator:#x}')
        loaded = re.search(r'(%[\w.]+) = load i16, ptr %[^,]+', core)
        require(loaded, 'Dynamic registration must use the prepared 16-bit requirement discriminator')
        widened = re.search(r'(%[\w.]+) = zext i16 '+re.escape(loaded[1])+r' to i64', core)
        blend = re.search(r'(%[\w.]+) = call i64 @llvm.ptrauth.blend\(i64 %[^,]+, i64 '+re.escape(widened[1])+r'\)', core) if widened else None
        require(blend and re.search(r'@llvm.ptrauth.resign\(i64 %[^,]+, i32 0, i64 0, i32 0, i64 '+re.escape(blend[1])+r'\)', core),
                'Dynamic registration must re-sign generic code pointers for their witness slots')
    else:
        require('llvm.ptrauth.' not in core, 'Unsigned dynamic registration unexpectedly signs pointers')
    return results

reports = []
for run in json.loads((ROOT/'run-report.json').read_text())['runs']:
    directory = ROOT / run['directory']
    provider, caller = [(directory/name).read_text() for name in ['provider.ll', 'caller.ll']]
    pac = run['target'].startswith(('arm64e-', 'arm64e.x1-'))
    word = 4 if run['target'].startswith('arm64_32-') else 8
    proto = next(line for line in provider.splitlines() if line.startswith('@"$s12WitnessProbe0B0Mp" ='))
    flags = [int(value) & 0xffffffff for value in re.findall(r'%swift.protocol_requirement \{ i32 (-?\d+), i32 0 \}', proto)]
    require([value & 0x3f for value in flags] == FLAGS, 'Requirement kinds, instance and async flags changed')
    require([value >> 16 for value in flags] == (EXPECTED_DISC if pac else [0]*9), 'Unexpected declaration discriminator')
    aliases = [line for line in provider.splitlines() if line.startswith('@"$s12WitnessProbe0B0P') and 'Tq" = alias %swift.protocol_requirement' in line]
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
    result['delegate'] = check_delegate(provider, caller, (directory/'provider.sil').read_text(),
                                        (directory/'registration.ll').read_text(), pac, word == 4,
                                        run['library_evolution'])
    result.update({'word_size':word,'pointer_authentication':pac,'requirements':[{'slot':i+1,'name':name,'flags':flags[i],'kind':flags[i]&15,'discriminator':flags[i]>>16} for i,name in enumerate(NAMES)],'tables':table_rows,'calls':calls,'generic_conformances':conformances})
    reports.append(result)
    print(f"PASS check {run['xcode']} {run['target']} evolution={run['library_evolution']}")
(ROOT/'evidence.json').write_text(json.dumps(reports,indent=2)+'\n')
print(f'Checked {len(reports)} compiler variants, {len(reports)*len(CALLERS)} dispatch paths, '
      f'{len(reports)*3} tables/patterns and {sum(len(item["delegate"]) for item in reports)} class-bound witness paths.')
