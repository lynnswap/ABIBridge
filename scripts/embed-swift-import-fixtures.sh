#!/bin/bash
set -euo pipefail

# These separately linked fixtures exercise real importing references on devices.
# The architecture helper must select the same ABI for the host and its packages.
[[ "$PLATFORM_NAME" == iphoneos ]] || exit 0
case "$ARCHS" in
    arm64|arm64e|arm64e.x1) ;;
    *) echo 'Select one device architecture when building the import fixtures.' >&2; exit 1 ;;
esac
root=$(cd "${PROJECT_DIR:?}/../.." && pwd)
output="${DERIVED_FILE_DIR:?}/SwiftImportFixtures"
# Recreate generated bundles so an unsigned build cannot retain an old signature.
rm -rf "$output"
arguments=(--output "$output" --architecture "$ARCHS")
if [[ "$CODE_SIGNING_ALLOWED" != NO && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    arguments+=(--sign "$EXPANDED_CODE_SIGN_IDENTITY")
fi
python3 "$root/scripts/build-swift-import-fixtures.py" \
    "${arguments[@]}"
for name in SwiftImportProvider SwiftImportCaller SwiftImportCallerControl; do
    destination="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/$name.framework"
    # Keep an old framework signature from surviving a later unsigned build.
    rm -rf "$destination"
    ditto "$output/$name.framework" "$destination"
done
