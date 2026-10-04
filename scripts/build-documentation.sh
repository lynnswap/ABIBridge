#!/bin/bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_output=${1:-"$task_root/.build/documentation"}
task_base_path=${2:-ABIBridge}
task_derived=$(mktemp -d "${TMPDIR:-/tmp}/abibridge-docs.XXXXXX")
trap 'find "$task_derived" -delete' EXIT

cd "$task_root"
xcodebuild docbuild \
  -scheme ABIBridgeSwiftUI \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$task_derived"

# Validate this package strictly without treating dependency documentation
# warnings as failures of ABIBridge's catalog.
task_symbol_graphs() {
  local task_module=$1
  local task_graphs
  for task_graphs in "$task_derived/Build/Intermediates.noindex/ABIBridge.build/Debug/$task_module.build/symbol-graph" \
                     "$task_derived/Build/Intermediates.noindex/ABIBridge.build/Debug/$task_module-t.build/symbol-graph"; do
    if [[ -d "$task_graphs" ]]; then
      echo "$task_graphs"
      return
    fi
  done
  echo "Missing symbol graphs for $task_module in $task_derived" >&2
  return 1
}
task_core_graphs=$(task_symbol_graphs ABIBridge)
task_swiftui_graphs=$(task_symbol_graphs ABIBridgeSwiftUI)
xcrun docc convert Sources/ABIBridge/ABIBridge.docc \
  --additional-symbol-graph-dir "$task_core_graphs" \
  --fallback-display-name ABIBridge \
  --fallback-bundle-identifier ABIBridge \
  --warnings-as-errors \
  --output-dir "$task_derived/ABIBridge.doccarchive"

xcrun docc convert Sources/ABIBridgeSwiftUI/ABIBridgeSwiftUI.docc \
  --additional-symbol-graph-dir "$task_swiftui_graphs" \
  --fallback-display-name ABIBridgeSwiftUI \
  --fallback-bundle-identifier ABIBridgeSwiftUI \
  --warnings-as-errors \
  --output-dir "$task_derived/ABIBridgeSwiftUI.doccarchive"

xcrun docc merge "$task_derived/ABIBridge.doccarchive" "$task_derived/ABIBridgeSwiftUI.doccarchive" \
  --synthesized-landing-page-name ABIBridge \
  --output-path "$task_derived/Combined.doccarchive"

xcrun docc process-archive transform-for-static-hosting \
  "$task_derived/Combined.doccarchive" \
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
