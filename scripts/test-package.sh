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

    # The complementary filters include new suites without maintaining a second list.
    task_suites=(SwiftImportedFunctionHookTests SwiftGenericBindingTests
        SwiftConstrainedExtensionTests SymbolResolutionTests
        SwiftExistentialValueTests SwiftMemberInvocationTests)
    task_only=()
    task_skip=()
    for task_name in "${task_suites[@]}"; do
        task_only+=("-only-testing:ABIBridgeTests/$task_name")
        task_skip+=("-skip-testing:ABIBridgeTests/$task_name")
    done

    mkdir -p "$task_build_dir/Logs/Test"
    task_results=$(mktemp -d "$task_build_dir/Logs/Test/api-parallel.XXXXXX")
    xcodebuild test-without-building "${task_options[@]}" "$@" \
        -parallel-testing-enabled NO -resultBundlePath "$task_results/selected.xcresult" \
        "${task_only[@]}" &
    task_selected_pid=$!
    xcodebuild test-without-building "${task_options[@]}" "$@" \
        -parallel-testing-enabled NO -resultBundlePath "$task_results/remaining.xcresult" \
        "${task_skip[@]}" &
    task_remaining_pid=$!

    task_status=0
    if ! wait "$task_selected_pid"; then task_status=1; fi
    if ! wait "$task_remaining_pid"; then task_status=1; fi
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
