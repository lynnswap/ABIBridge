#!/bin/bash
set -euo pipefail

task_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
task_mode=${1:-calls}
task_build=${ABI_BENCHMARK_BUILD_DIR:-"$task_root/.build/runtime-benchmarks"}
case "$task_mode" in
  calls|search) ;;
  *) echo "Usage: $0 [calls|search]" >&2; exit 2 ;;
esac

xcrun swift build --package-path "$task_root/Tools/RuntimeBenchmarks" \
  --scratch-path "$task_build" -c release --product RuntimeBenchmarks
task_bin=$(xcrun swift build --package-path "$task_root/Tools/RuntimeBenchmarks" \
  --scratch-path "$task_build" -c release --show-bin-path)
if [[ "$task_mode" == calls ]]; then
  "$task_bin/RuntimeBenchmarks" calls
  exit
fi

task_providers=$(mktemp -d "${TMPDIR:-/tmp}/abibridge-search-benchmarks.XXXXXX")
trap 'find "$task_providers" -delete' EXIT
python3 - "$task_providers" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for count in [100, 1000, 10000]:
    cpp = 'namespace LookupBench {\n' + '\n'.join(
        f'int f{index}() {{ return {index}; }}' for index in range(count)) + '\n}\n'
    cpp += '\n'.join(f'extern "C" int lookup_C{index}() {{ return {index}; }}' for index in range(count))
    (root / f'Symbols{count}.cpp').write_text(cpp)
    (root / f'SwiftSymbols{count}.swift').write_text('\n'.join(
        f'@inline(never) public func f{index}() -> Int32 {{ {index} }}' for index in range(count)))
PY
for task_count in 100 1000 10000; do
  xcrun clang++ -O2 -std=c++20 -dynamiclib "$task_providers/Symbols$task_count.cpp" \
    -o "$task_providers/libSymbols$task_count.dylib"
  xcrun swiftc -O -swift-version 6 -parse-as-library -emit-library -enable-library-evolution \
    -module-name SwiftLookupBench "$task_providers/SwiftSymbols$task_count.swift" \
    -o "$task_providers/libSwiftSymbols$task_count.dylib"
done
"$task_bin/RuntimeBenchmarks" search "$task_providers"
