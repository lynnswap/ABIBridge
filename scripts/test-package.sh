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

task_status=0
for task_scheme in "${task_schemes[@]}"; do
    if ! xcodebuild test -workspace "$task_root/ABIBridge.xcworkspace" -scheme "$task_scheme" \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "${ABI_TEST_BUILD_DIR:-$task_root/.build/package-tests/$task_suite}" "$@"; then
        task_status=1
    fi
done
exit "$task_status"
