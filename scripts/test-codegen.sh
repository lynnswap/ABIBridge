#!/bin/bash
# Compare the conventions ABIBridge relies on with the code that the selected
# Swift compiler emits. A new toolchain can change them, so CI runs these
# checks with each supported Xcode.
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_checks=(
    check-inferred-swift-value-codegen.py
    check-inferred-swift-value-evidence-codegen.py
    check-swift-borrowed-input-codegen.py
    check-objc-requirement-shape-codegen.py
    generate-objc-requirement-names.py
    check-managed-swift-codegen.py
    check-swift-closure-codegen.py
    check-swift-optional-codegen.py
    check-swift-collection-codegen.py
    check-swift-generic-codegen.py
    check-swift-generic-call-codegen.py
    check-swift-generic-receiver-codegen.py
    check-swift-witness-codegen.py
    check-explicit-swift-value-codegen.py
    check-indirect-swift-value-codegen.py
    check-swift-tuple-result-codegen.py
    check-swift-error-codegen.py
    check-swift-async-codegen.py
    check-swift-throwing-closure-codegen.py
    check-swift-async-closure-codegen.py
    check-swift-argument-codegen.py
    check-swift-existential-codegen.py
    check-swift-opaque-codegen.py
    check-swiftui-codegen.py
)
task_logs=$(mktemp -d "${TMPDIR:-/tmp}/abibridge-codegen.XXXXXX")
trap 'find "$task_logs" -delete' EXIT

# Each check compiles its own sources, so they run side by side. Their output
# is kept apart and printed in order. Run every check so one failure does not
# hide the others.
export task_root task_logs
printf '%s\n' "${task_checks[@]}" | xargs -n 1 -P "$(sysctl -n hw.ncpu)" bash -c '
    task_command=(python3 "$task_root/scripts/$1")
    if [[ "$1" == generate-objc-requirement-names.py ]]; then task_command+=(--check); fi
    "${task_command[@]}" > "$task_logs/$1.log" 2>&1 && touch "$task_logs/$1.passed"
' _ || true

task_failed=()
for task_check in "${task_checks[@]}"; do
    if [[ -e "$task_logs/$task_check.log" ]]; then cat "$task_logs/$task_check.log"; fi
    if [[ ! -e "$task_logs/$task_check.passed" ]]; then
        task_failed+=("$task_check")
    fi
done
if [[ ${#task_failed[@]} -gt 0 ]]; then
    echo "Failed compiler checks: ${task_failed[*]}" >&2
    exit 1
fi
