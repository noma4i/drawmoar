#!/bin/sh
set -eu
. "$(dirname -- "$0")/config.sh"
failed=0
if xcode-select -p >/dev/null 2>&1 && xcrun --find xcodebuild >/dev/null 2>&1; then
    echo "Xcode: $(xcode-select -p)"
else
    echo "Xcode: select a full Xcode installation with xcode-select."; failed=1
fi
if command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen: $(command -v xcodegen)"
else
    echo "xcodegen: missing. Run: brew install xcodegen"; failed=1
fi
if security find-identity -v -p codesigning | grep -q '"Apple Development:'; then
    echo "Apple Development identity: found"
else
    echo "Apple Development identity: missing. Sign in to Xcode and create a development certificate."; failed=1
fi
if devices=$(xcrun devicectl list devices --timeout 30 --json-output - 2>/dev/null | python3 "$root/scripts/devices.py" /dev/stdin); then
    if [ -n "$devices" ]; then printf 'Connected devices:\n%s\n' "$devices"; else echo "Connected devices: none. Connect and trust an iPhone or iPad."; failed=1; fi
else
    echo "Could not list devices. Check Xcode and the device connection."; failed=1
fi
if [ "$failed" -eq 0 ]; then echo "Ready to build for a device."; else echo "Fix the items above before building for a device."; fi
exit "$failed"
