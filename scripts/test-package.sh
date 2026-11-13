#!/bin/bash
set -euo pipefail

task_suite=${1:-all}
if [[ $# -gt 0 ]]; then shift; fi
task_root=$(cd "$(dirname "$0")/.." && pwd)
case "$task_suite" in
    runtime) task_schemes=(ABIBridgeRuntime) ;;
    api) task_schemes=(ABIBridge) ;;
    local) task_schemes=(ABIBridgeLocal) ;;
    all) task_schemes=(ABIBridgeRuntime ABIBridge ABIBridgeLocal) ;;
    *) echo "Usage: $0 [all|runtime|api|local] [xcodebuild options...]" >&2; exit 2 ;;
esac

task_build_dir=${ABI_TEST_BUILD_DIR:-$task_root/.build/package-tests/$task_suite}
if [[ "$task_suite" == api && "${ABI_TEST_PARALLEL_API:-0}" == 1 ]]; then
    task_options=(-workspace "$task_root/ABIBridge.xcworkspace" -scheme ABIBridge
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$task_build_dir")
    xcodebuild build-for-testing "${task_options[@]}" "$@"

    # Three groups name suites that take about as long together as each other
    # group. The fourth takes every other suite, so a new suite needs no entry.
    task_group_1=(SwiftOpaqueResultTests SwiftRuntimeValueProjectionTests
        SwiftRuntimeValueTests SwiftExistentialValueTests
        SwiftFunctionInvocationTests SwiftWitnessDispatchTests
        SymbolResolutionTests SwiftVirtualReplacementTests)
    task_group_2=(SwiftMemberInvocationTests ResolutionRequestTests
        RuntimePreparationTests SwiftGenericCallTests SwiftGenericReceiverTests
        SwiftClassHookTests SwiftGenericBindingTests SwiftCallbackTests)
    task_group_3=(SwiftConstrainedExtensionTests ConformanceMatrixTests
        SwiftImportedFunctionHookTests NativeSwiftClosureTests
        SwiftInferredValueTests SwiftSignatureCompatibilityTests
        SwiftRuntimeCollectionTests SwiftGenericValueReceiverTests)

    mkdir -p "$task_build_dir/Logs/Test"
    task_results=$(mktemp -d "$task_build_dir/Logs/Test/api-parallel.XXXXXX")
    task_pids=()
    for task_group in 1 2 3 4; do
        task_filters=()
        if [[ "$task_group" == 4 ]]; then
            for task_name in "${task_group_1[@]}" "${task_group_2[@]}" "${task_group_3[@]}"; do
                task_filters+=("-skip-testing:ABIBridgeTests/$task_name")
            done
        else
            task_names="task_group_$task_group[@]"
            for task_name in "${!task_names}"; do
                task_filters+=("-only-testing:ABIBridgeTests/$task_name")
            done
        fi
        xcodebuild test-without-building "${task_options[@]}" "$@" \
            -parallel-testing-enabled NO \
            -resultBundlePath "$task_results/group-$task_group.xcresult" \
            "${task_filters[@]}" &
        task_pids+=($!)
    done

    task_status=0
    for task_pid in "${task_pids[@]}"; do
        if ! wait "$task_pid"; then task_status=1; fi
    done
    exit "$task_status"
fi

task_status=0
for task_scheme in "${task_schemes[@]}"; do
    if ! xcodebuild test -workspace "$task_root/ABIBridge.xcworkspace" -scheme "$task_scheme" \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$task_build_dir" "$@"; then
        task_status=1
    fi
done
exit "$task_status"
