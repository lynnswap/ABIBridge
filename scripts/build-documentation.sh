#!/bin/bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_output=${1:-"$task_root/.build/documentation"}
task_base_path=${2:-ABIBridge}
task_derived=$(mktemp -d "${TMPDIR:-/tmp}/abibridge-docs.XXXXXX")
trap 'find "$task_derived" -delete' EXIT

cd "$task_root"
xcodebuild docbuild \
  -scheme ABIBridge \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$task_derived"

# Validate this package strictly without treating dependency documentation
# warnings as failures of ABIBridge's catalog.
xcrun docc convert Sources/ABIBridge/ABIBridge.docc \
  --additional-symbol-graph-dir "$task_derived/Build/Intermediates.noindex/ABIBridge.build/Debug/ABIBridge.build/symbol-graph" \
  --fallback-display-name ABIBridge \
  --fallback-bundle-identifier ABIBridge \
  --warnings-as-errors \
  --output-dir "$task_derived/ABIBridge.doccarchive"

xcrun docc process-archive transform-for-static-hosting \
  "$task_derived/ABIBridge.doccarchive" \
  --output-path "$task_output" \
  --hosting-base-path "$task_base_path"

cat > "$task_output/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>ABIBridge Documentation</title>
<meta http-equiv="refresh" content="0;url=./documentation/abibridge/">
<a href="./documentation/abibridge/">ABIBridge Documentation</a>
</html>
HTML
