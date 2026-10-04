#!/bin/bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_fixture=$(mktemp -d "${TMPDIR:-/tmp}/abibridge-native.XXXXXX")
trap 'find "$task_fixture" -delete' EXIT

task_mode=${1:-all}
case "$task_mode" in
    all|focused|swiftui) ;;
    *) echo "Usage: $0 [all|focused|swiftui]" >&2; exit 2 ;;
esac
task_build=${ABI_CONSUMER_BUILD_DIR:-"$task_root/.build/native-consumer"}

check_swiftui() {
    xcrun swiftc -swift-version 6 -parse-as-library -emit-library -enable-library-evolution \
        -module-name SwiftUIPlugin "$task_root/Tests/NativeConsumer/SwiftUIPlugin.swift" \
        -o "$task_fixture/libSwiftUIPlugin.dylib"
    xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
        --scratch-path "$task_build" SwiftUIConsumer "$task_fixture/libSwiftUIPlugin.dylib"
    local task_bin
    task_bin=$(xcrun swift build --package-path "$task_root/Tests/NativeConsumer" \
        --scratch-path "$task_build" --show-bin-path)
    python3 "$task_root/scripts/check-swiftui-consumer-contract.py" "$task_bin"
}

if [[ "$task_mode" == swiftui ]]; then
    check_swiftui
    exit
fi

xcrun clang++ -std=c++20 -dynamiclib -mmacosx-version-min=15.4 \
    "$task_root/Tests/NativeConsumer/Fixture.cpp" \
    -o "$task_fixture/libFixture.dylib"
xcrun swiftc -parse-as-library -emit-library -emit-module -enable-library-evolution \
    -module-name SwiftFunctionFixture -emit-module-path "$task_fixture/SwiftFunctionFixture.swiftmodule" \
    "$task_root/Tests/NativeConsumer/SwiftFixture.swift" \
    -o "$task_fixture/libSwiftFixture.dylib"
xcrun swiftc -parse-as-library -emit-library -enable-library-evolution \
    -module-name SwiftExtensionFixture -I "$task_fixture" -L "$task_fixture" -lSwiftFixture \
    -Xlinker -rpath -Xlinker "$task_fixture" -Xlinker -no_data_const \
    "$task_root/Tests/NativeConsumer/SwiftExtensionFixture.swift" \
    -o "$task_fixture/libSwiftExtensionFixture.dylib"
xcrun clang -std=c11 -pedantic-errors -fsyntax-only \
    -I "$task_root/Sources/ABIBridgeCore/include" \
    "$task_root/Tests/NativeConsumer/Sources/CInspectionConsumer/main.c"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftExplicitValueConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftAsyncConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" CXXInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" ObjCXXInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" -c release CInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftFunctionConsumer "$task_fixture/libSwiftFixture.dylib" "$task_fixture/libSwiftExtensionFixture.dylib"

if [[ "$task_mode" == focused ]]; then exit; fi

python3 "$task_root/scripts/check-managed-swift-codegen.py"
python3 "$task_root/scripts/check-swift-closure-codegen.py"
python3 "$task_root/scripts/check-swift-collection-codegen.py"
python3 "$task_root/scripts/check-swift-generic-codegen.py"
python3 "$task_root/scripts/check-swift-generic-call-codegen.py"
python3 "$task_root/scripts/check-swift-generic-receiver-codegen.py"
python3 "$task_root/scripts/check-explicit-swift-value-codegen.py"
python3 "$task_root/scripts/check-indirect-swift-value-codegen.py"
python3 "$task_root/scripts/check-swift-error-codegen.py"
python3 "$task_root/scripts/check-swift-async-codegen.py"
python3 "$task_root/scripts/check-swift-throwing-closure-codegen.py"
python3 "$task_root/scripts/check-swift-async-closure-codegen.py"
python3 "$task_root/scripts/check-swift-argument-codegen.py"
python3 "$task_root/scripts/check-swift-existential-codegen.py"
python3 "$task_root/scripts/check-swift-opaque-codegen.py"
python3 "$task_root/scripts/check-swiftui-codegen.py"

xcrun swiftc -parse-as-library -emit-library -emit-module -enable-library-evolution -enable-experimental-feature Lifetimes \
    -module-name ManagedSwiftFixtures -emit-module-path "$task_fixture/ManagedSwiftFixtures.swiftmodule" \
    "$task_root/Tests/ManagedSwiftFixtures/Values.swift" "$task_root/Tests/ManagedSwiftFixtures/Generics.swift" \
    "$task_root/Tests/ManagedSwiftFixtures/Errors.swift" "$task_root/Tests/ManagedSwiftFixtures/Async.swift" \
    "$task_root/Tests/ManagedSwiftFixtures/ParameterConventions.swift" \
    "$task_root/Tests/ManagedSwiftFixtures/Existentials.swift" \
    "$task_root/Tests/ManagedSwiftFixtures/RuntimeValues.swift" "$task_root/Tests/ManagedSwiftFixtures/GenericCalls.swift" \
    "$task_root/Tests/ManagedSwiftFixtures/ExplicitValues.swift" "$task_root/Tests/ManagedSwiftFixtures/ClosureValues.swift" \
    -o "$task_fixture/libManagedSwiftFixtures.dylib"
python3 "$task_root/scripts/build-swift-import-fixtures.py" --sdk macosx --architecture "$(uname -m)" \
    --output "$task_fixture/SwiftImportFixtures"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftRuntimeValueConsumer \
    "$task_fixture/libManagedSwiftFixtures.dylib" "$task_fixture/SwiftImportFixtures"
xcrun swiftc -parse-as-library -emit-library -module-name ManagedSwiftAdapters \
    -I "$task_fixture" -L "$task_fixture" -lManagedSwiftFixtures -Xlinker -rpath -Xlinker "$task_fixture" \
    "$task_root/Tests/ManagedSwiftAdapters/Adapters.swift" "$task_root/Tests/ManagedSwiftAdapters/GenericAdapters.swift" \
    -o "$task_fixture/libManagedSwiftAdapters.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftGenericConsumer "$task_fixture/libManagedSwiftAdapters.dylib"

xcrun clang -std=c11 -dynamiclib -mmacosx-version-min=15.4 -undefined dynamic_lookup \
    "$task_root/Tests/NativeConsumer/ErrorLeaseFixture.c" -o "$task_fixture/libErrorLease.dylib"
xcrun clang -std=c11 -dynamiclib -mmacosx-version-min=15.4 \
    "$task_root/Tests/NativeConsumer/ThrowingClosureFactory.c" -o "$task_fixture/libErrorClosureFactory.dylib"
xcrun clang++ -std=c++20 -dynamiclib -mmacosx-version-min=15.4 -undefined dynamic_lookup \
    "$task_root/Tests/NativeConsumer/AsyncClosureLeaseFixture.cpp" -o "$task_fixture/libAsyncClosureLease.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftErrorConsumer "$task_fixture/libErrorLease.dylib" "$task_fixture/libErrorClosureFactory.dylib" "$task_fixture/libAsyncClosureLease.dylib"

xcrun clang -std=c11 -dynamiclib -mmacosx-version-min=15.4 \
    "$task_root/Tests/NativeConsumer/ClosureLeaseFixture.c" \
    -o "$task_fixture/libClosureLease.dylib"

xcrun clang++ -std=c++20 -dynamiclib -mmacosx-version-min=15.4 \
    -undefined dynamic_lookup -Wl,-install_name,@rpath/ABIBridgeConstructor.dylib "$task_root/Tests/NativeConsumer/Constructor.cpp" \
    -o "$task_fixture/libConstructor.dylib"
xcrun swift build --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" --product LoadingConsumer
task_loading_bin=$(xcrun swift build --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" --show-bin-path)
mkdir -p "$task_loading_bin/LoadingFixtures"
xcrun clang++ -std=c++20 -dynamiclib -mmacosx-version-min=15.4 -undefined dynamic_lookup \
    -Wl,-install_name,@rpath/libLoadingFixture.dylib \
    "$task_root/Tests/NativeConsumer/LoadingFixture.cpp" \
    -o "$task_loading_bin/LoadingFixtures/libLoadingFixture.dylib"
mkdir -p "$task_loading_bin/LoadingFixtures/other"
for task_identity in Actual Alias; do
    task_identity_value=1
    task_identity_directory="$task_loading_bin/LoadingFixtures"
    if [[ "$task_identity" == Alias ]]; then
        task_identity_value=2
        task_identity_directory="$task_loading_bin/LoadingFixtures/other"
    fi
    xcrun clang -dynamiclib -mmacosx-version-min=15.4 \
        -Wl,-install_name,@rpath/libIdentityShared.dylib -DFIXTURE_VALUE="$task_identity_value" \
        "$task_root/Tests/NativeConsumer/ImageIdentityFixture.c" \
        -o "$task_identity_directory/libIdentity$task_identity.dylib"
done
ln -sf libIdentityActual.dylib "$task_loading_bin/LoadingFixtures/libIdentityAlias.dylib"
"$task_loading_bin/LoadingConsumer" "$task_loading_bin/LoadingFixtures/libLoadingFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" MRCXXInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" ObjCInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" \
    NativeConsumer "$task_fixture/libFixture.dylib" "$task_fixture/libConstructor.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" ObjCConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" MRCConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" DynamicConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftObjectConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftClosureConsumer "$task_fixture/libSwiftFixture.dylib" "$task_fixture/libClosureLease.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftMemberConsumer "$task_fixture/libSwiftFixture.dylib" "$task_fixture/libSwiftExtensionFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_build" SwiftInitializerHookConsumer
xcrun clang -std=c11 -pedantic-errors -fsyntax-only \
    -I "$task_root/Sources/ABIBridgeCore/include" \
    -I "$task_root/Tests/NativeConsumer/Sources/HookFixture/include" \
    "$task_root/Tests/NativeConsumer/Sources/CHookConsumer/main.c"
for task_hook_consumer in CHookConsumer CXXHookConsumer ObjCXXHookConsumer MRCXXHookConsumer MixedHookConsumer CoordinatedHookConsumer; do
    xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
        --scratch-path "$task_build" "$task_hook_consumer"
done

xcrun clang -dynamiclib -mmacosx-version-min=15.4 "$task_root/Tests/NativeConsumer/ImportedHookProvider.c" -o "$task_fixture/libImportedProvider.dylib"
xcrun clang -dynamiclib -mmacosx-version-min=15.4 "$task_root/Tests/NativeConsumer/ImportedHookLibrary.c" "$task_fixture/libImportedProvider.dylib" -o "$task_fixture/libImportedCaller.dylib"
for task_hook_consumer in ImportedHookConsumer ObjCXXImportedHookConsumer; do
    xcrun swift run --package-path "$task_root/Tests/NativeConsumer" --scratch-path "$task_build" "$task_hook_consumer" "$task_fixture/libImportedCaller.dylib"
done

# Run unload/reload monitoring in isolated consumers, without resolver test caches.
xcrun clang -dynamiclib -mmacosx-version-min=15.4 "$task_root/Tests/NativeConsumer/ImportedHookProvider.c" "$task_root/Tests/NativeConsumer/ImportedMonitorProvider.c" -o "$task_fixture/libMonitorProvider.dylib"
for task_monitor_caller in MonitorCaller MonitorCancel; do
    xcrun clang -dynamiclib -mmacosx-version-min=15.4 "$task_root/Tests/NativeConsumer/ImportedMonitorLibrary.c" "$task_fixture/libMonitorProvider.dylib" -o "$task_fixture/lib$task_monitor_caller.dylib"
done
for task_monitor_consumer in ImportedMonitorConsumer ObjCXXImportedMonitorConsumer; do
    xcrun swift run --package-path "$task_root/Tests/NativeConsumer" --scratch-path "$task_build" "$task_monitor_consumer" "$task_fixture/libMonitorProvider.dylib" "$task_fixture/libMonitorCaller.dylib" "$task_fixture/libMonitorCancel.dylib"
done

# This executable deliberately permits writes to its compiler-emitted vtables.
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" --scratch-path "$task_build" VirtualMutationConsumer

xcrun swift run --package-path "$task_root/Tests/NativeConsumer" --scratch-path "$task_build" ManagedVirtualConsumer "$task_fixture/libImportedCaller.dylib"

# Shared-table mutation control; this writable setting applies only to the fixture.
xcrun clang++ -std=c++20 -O2 -dynamiclib -mmacosx-version-min=15.4 -Wl,-no_data_const \
    "$task_root/Tests/NativeConsumer/VirtualHookFixture.cpp" -o "$task_fixture/libVirtualHook.dylib"
printf '#include <ABIBridge/VirtualHooks.h>\n' | xcrun clang -x c -std=c11 -pedantic-errors -fsyntax-only \
    -I "$task_root/Sources/ABIBridgeCore/include" -
for task_virtual_consumer in CVirtualHookConsumer VirtualHookConsumer ObjCXXVirtualHookConsumer; do
    xcrun swift run --package-path "$task_root/Tests/NativeConsumer" --scratch-path "$task_build" \
        "$task_virtual_consumer" "$task_fixture/libVirtualHook.dylib"
done

check_swiftui
