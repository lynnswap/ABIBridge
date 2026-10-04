#!/bin/bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_fixture=$(mktemp -d "${TMPDIR:-/tmp}/abibridge-swiftui-preparation.XXXXXX")
trap 'find "$task_fixture" -delete' EXIT

for configuration in debug release; do
    flags=(-Onone)
    if [[ "$configuration" == release ]]; then flags=(-O); fi
    xcrun swiftc -swift-version 6 -parse-as-library -emit-library -enable-library-evolution \
        "${flags[@]}" -module-name SwiftUIPlugin "$task_root/Tests/NativeConsumer/SwiftUIPlugin.swift" \
        -o "$task_fixture/libSwiftUIPlugin.dylib"
    xcrun swift build --package-path "$task_root/Tests/NativeConsumer" \
        --scratch-path "$task_root/.build/native-consumer" -c "$configuration" --product SwiftUIConsumer
    task_bin=$(xcrun swift build --package-path "$task_root/Tests/NativeConsumer" \
        --scratch-path "$task_root/.build/native-consumer" -c "$configuration" --show-bin-path)
    for run in 1 2 3; do
        echo "$configuration process $run"
        "$task_bin/SwiftUIConsumer" "$task_fixture/libSwiftUIPlugin.dylib" --measure-preparation
    done
    "$task_bin/SwiftUIConsumer" "$task_fixture/libSwiftUIPlugin.dylib"
done
