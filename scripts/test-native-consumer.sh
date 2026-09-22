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
