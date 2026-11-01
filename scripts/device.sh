#!/bin/sh
set -eu
if [ "${1-}" = "--help" ]; then
    echo "Usage: scripts/device.sh [device name or identifier]"
    exit 0
fi
if [ "$#" -gt 1 ]; then echo "Usage: scripts/device.sh [device name or identifier]" >&2; exit 1; fi
. "$(dirname -- "$0")/config.sh"
if ! command -v xcodegen >/dev/null 2>&1 || ! xcrun --find xcodebuild >/dev/null 2>&1; then
    echo "Xcode or xcodegen is missing. Run scripts/doctor.sh." >&2; exit 1
fi
if ! devices=$(xcrun devicectl list devices --timeout 30 --json-output - 2>/dev/null | python3 "$root/scripts/devices.py" /dev/stdin); then
    echo "Could not list devices. Check Xcode and the device connection." >&2; exit 1
fi
if [ -z "$devices" ]; then echo "No connected iPhone or iPad. Connect, unlock, and trust this Mac." >&2; exit 1; fi
if ! device=$(printf '%s\n' "$devices" | python3 -c '
import sys
rows = [line.rstrip("\n").split("\t") for line in sys.stdin]
query = sys.argv[1] or None
matches = [row for row in rows if query is None or query in row]
if len(matches) != 1:
    print("Select one connected device by name or identifier:", file=sys.stderr)
    for row in rows:
        print("  " + "  ".join(row), file=sys.stderr)
    sys.exit(1)
print(matches[0][1])
' "${1-}"); then exit 1; fi
"$root/scripts/gen.sh"
if ! xcodebuild -project "$root/DrawMoar.xcodeproj" -scheme DrawMoar -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$root/.build/device.noindex" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build; then
    echo "Build or signing failed. Check the Team ID, bundle ID, Xcode account, and device registration." >&2; exit 1
fi
if ! xcrun devicectl device install app --device "$device" "$root/.build/device.noindex/Build/Products/Debug-iphoneos/DrawMoar.app"; then
    echo "Install failed. Unlock and trust the device, and enable Developer Mode." >&2; exit 1
fi
if ! xcrun devicectl device process launch --device "$device" "$DRAWMOAR_BUNDLE_ID"; then
    echo "Launch failed. Enable Developer Mode and trust the developer on the device." >&2; exit 1
fi
