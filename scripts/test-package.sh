#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <all|core|invocation|hooks> [xcodebuild options...]" >&2
    exit 2
fi
shard=$1
shift
root=$(cd "$(dirname "$0")/.." && pwd)

invocation=(
    CFunctionInvocationTests CXXObjectInvocationTests CallerDescribedValueTests NativeRuntimeTests
    ObjectiveCAggregateTests ObjectiveCBlockTests ObjectiveCImplementationTests ObjectiveCInvocationTests
    ObjectiveCIvarTests SwiftCallBoundaryTests SwiftFunctionInvocationTests
    SwiftMemberInvocationTests ManagedSwiftValueTests SwiftClosureABITests NativeSwiftClosureTests
    SwiftCollectionValueTests SwiftGenericMetadataTests SwiftExplicitValueTests SwiftIndirectValueTests SwiftErrorABITests SwiftThrowingInvocationTests SwiftAsyncABITests
)
hooks=(
    CoordinatedObjectiveCHookTests HookInvocationDiagnosticsTests
    ImportedFunctionHookTests ImportedFunctionMonitorTests
    ObjectiveCInitializerHookTests ObjectiveCMethodHookTests ObjectiveCReplacementTests
    SwiftCallbackTests SwiftClassHookTests SwiftImportedFunctionHookTests
    SwiftImportedReplacementTests SwiftReplacementTests SwiftValueHookTests
    SwiftVirtualReplacementTests VirtualHookTests
)

arguments=(test -workspace "$root/ABIBridge.xcworkspace" -scheme ABIBridge
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "${ABI_TEST_BUILD_DIR:-$root/.build/package-tests/$shard}")
case "$shard" in
    all) ;;
    core)
        # The complement includes every unassigned suite, including future tests.
        # Use exactly the same selectors as the two explicit shards below.
        for suite in "${invocation[@]}" "${hooks[@]}"; do
            arguments+=("-skip-testing:ABIBridgeTests/$suite")
        done
        ;;
    invocation)
        for suite in "${invocation[@]}"; do arguments+=("-only-testing:ABIBridgeTests/$suite"); done
        ;;
    hooks)
        for suite in "${hooks[@]}"; do arguments+=("-only-testing:ABIBridgeTests/$suite"); done
        ;;
    *) echo "Unknown package test shard: $shard" >&2; exit 2 ;;
esac
exec xcodebuild "${arguments[@]}" "$@"
