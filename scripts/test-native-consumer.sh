#!/bin/bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_fixture=$(mktemp -d "${TMPDIR:-/tmp}/abibridge-native.XXXXXX")
trap 'find "$task_fixture" -delete' EXIT

xcrun clang++ -std=c++20 -dynamiclib -mmacosx-version-min=15.4 \
    "$task_root/Tests/NativeConsumer/Fixture.cpp" \
    -o "$task_fixture/libFixture.dylib"
xcrun clang++ -std=c++20 -dynamiclib -mmacosx-version-min=15.4 \
    -undefined dynamic_lookup "$task_root/Tests/NativeConsumer/Constructor.cpp" \
    -o "$task_fixture/libConstructor.dylib"
xcrun swiftc -parse-as-library -emit-library -emit-module -enable-library-evolution \
    -module-name SwiftFunctionFixture -emit-module-path "$task_fixture/SwiftFunctionFixture.swiftmodule" \
    "$task_root/Tests/NativeConsumer/SwiftFixture.swift" \
    -o "$task_fixture/libSwiftFixture.dylib"
xcrun swiftc -parse-as-library -emit-library -enable-library-evolution \
    -module-name SwiftExtensionFixture -I "$task_fixture" -L "$task_fixture" -lSwiftFixture \
    -Xlinker -rpath -Xlinker "$task_fixture" \
    "$task_root/Tests/NativeConsumer/SwiftExtensionFixture.swift" \
    -o "$task_fixture/libSwiftExtensionFixture.dylib"
xcrun clang -std=c11 -pedantic-errors -fsyntax-only \
    -I "$task_root/Sources/ABIBridgeCore/include" \
    "$task_root/Tests/NativeConsumer/Sources/CInspectionConsumer/main.c"
xcrun swift build --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" --product LoadingConsumer
task_loading_bin=$(xcrun swift build --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" --show-bin-path)
mkdir -p "$task_loading_bin/LoadingFixtures"
xcrun clang++ -std=c++20 -dynamiclib -mmacosx-version-min=15.4 -undefined dynamic_lookup \
    -Wl,-install_name,@rpath/libLoadingFixture.dylib \
    "$task_root/Tests/NativeConsumer/LoadingFixture.cpp" \
    -o "$task_loading_bin/LoadingFixtures/libLoadingFixture.dylib"
"$task_loading_bin/LoadingConsumer" "$task_loading_bin/LoadingFixtures/libLoadingFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" CXXInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" ObjCXXInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" MRCXXInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" CInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" ObjCInspectionConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" \
    NativeConsumer "$task_fixture/libFixture.dylib" "$task_fixture/libConstructor.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" ObjCConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" MRCConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" DynamicConsumer
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" SwiftConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" SwiftObjectConsumer "$task_fixture/libFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" SwiftFunctionConsumer "$task_fixture/libSwiftFixture.dylib"
xcrun swift run --package-path "$task_root/Tests/NativeConsumer" \
    --scratch-path "$task_root/.build/native-consumer" SwiftMemberConsumer "$task_fixture/libSwiftFixture.dylib" "$task_fixture/libSwiftExtensionFixture.dylib"
