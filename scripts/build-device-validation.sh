#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <arm64|arm64e|arm64e.x1> [xcodebuild options...]" >&2
    exit 2
fi
architecture=$1
shift
case "$architecture" in
    arm64|arm64e|arm64e.x1) ;;
    *) echo "Unsupported architecture: $architecture" >&2; exit 2 ;;
esac
configuration=${ABI_VALIDATION_CONFIGURATION:-Release}
root=$(cd "$(dirname "$0")/.." && pwd)
build_directory=${ABI_VALIDATION_BUILD_DIR:-"$root/.build/device-validation/$architecture"}
# Command-line settings apply to the application and every package dependency.
# Changing ARCHS only on the application target can silently mix ABI variants.
exec xcodebuild build \
    -workspace "$root/ABIBridge.xcworkspace" \
    -scheme ArchitectureTestHost \
    -configuration "$configuration" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$build_directory" \
    ARCHS="$architecture" ONLY_ACTIVE_ARCH=NO \
    IPHONEOS_DEPLOYMENT_TARGET=18.4 \
    "$@"
