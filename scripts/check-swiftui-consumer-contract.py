#!/usr/bin/env python3
"""Verify the public SwiftUI isolation contract and native-only link boundary."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
binary = Path(sys.argv[1])
module_directory = binary / 'Modules' if (binary / 'Modules/ABIBridge.swiftmodule').exists() else binary
for module in ['ABIBridge', 'ABIBridgeSwiftUI']:
    if not (module_directory / (module + '.swiftmodule')).exists():
        raise RuntimeError(f'Missing build input: {module}.swiftmodule in {module_directory}')
command = ['xcrun', 'swiftc', '-swift-version', '6', '-typecheck', '-I', str(module_directory),
           '-I', str(root / 'Sources/ABIBridgeCore/include'),
           '-I', str(root / 'Sources/ABIBridgeObjCXX/include')]
for module in ['MachOKitC', 'ZDLibffi']:
    candidates = [binary / (module + '.build/module.modulemap'),
                  binary.parent.parent / 'Intermediates.noindex/GeneratedModuleMaps' / (module + '.modulemap')]
    module_map = next((path for path in candidates if path.is_file()), None)
    if module_map is None:
        raise RuntimeError(f'Missing build input: {module} module map; checked {candidates}')
    command += ['-Xcc', '-fmodule-map-file=' + str(module_map)]
source = '''import ABIBridge
import ABIBridgeSwiftUI
func invalidCall(_ value: NativeSwiftValue) throws { _ = try NativeSwiftView(value) }
func requiresSendable<T: Sendable>(_ value: T) {}
@MainActor func invalidSend(_ view: NativeSwiftView) { requiresSendable(view) }
'''
with tempfile.TemporaryDirectory(prefix='abibridge-swiftui-contract-') as directory:
    file = Path(directory) / 'Isolation.swift'
    file.write_text('import ABIBridge\nimport ABIBridgeSwiftUI\n')
    imports = subprocess.run([*command, str(file)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if imports.returncode != 0:
        raise RuntimeError('Unable to import built products:\n' + imports.stdout)
    file.write_text(source)
    result = subprocess.run([*command, str(file)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    diagnostics = '\n'.join(line for line in result.stdout.splitlines() if 'error:' in line)
    if result.returncode != 1 or 'main actor-isolated initializer' not in diagnostics or "does not conform to the 'Sendable' protocol" not in diagnostics:
        raise RuntimeError('Public isolation contract changed:\n' + result.stdout)

libraries = subprocess.check_output(['xcrun', 'otool', '-L', str(binary / 'CInspectionConsumer')], text=True)
if '/SwiftUI.framework/' in libraries or '/SwiftUICore.framework/' in libraries:
    raise RuntimeError('The native-only product acquired a SwiftUI dependency:\n' + libraries)
print('SwiftUI public contract passed: MainActor construction, non-Sendable value, and independent native-only linkage')
