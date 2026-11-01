#!/bin/sh
set -eu
. "$(dirname -- "$0")/config.sh"
if [ "$#" -gt 1 ]; then echo "Usage: scripts/simulator.sh [simulator UDID]" >&2; exit 1; fi
if [ "$#" -eq 1 ]; then
    simulator=$1
else
    simulator=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; devices=[d for group in json.load(sys.stdin)["devices"].values() for d in group if d["state"] == "Booted"]; print(devices[0]["udid"] if len(devices) == 1 else "")')
    if [ -z "$simulator" ]; then echo "Pass a simulator UDID when there is not exactly one booted simulator. List them with xcrun simctl list devices available." >&2; exit 1; fi
fi
"$root/scripts/gen.sh"
xcodebuild -project "$root/DrawMoar.xcodeproj" -scheme DrawMoar -configuration Debug -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$root/.build/simulator.noindex" build
xcrun simctl boot "$simulator" 2>/dev/null || :
xcrun simctl bootstatus "$simulator" -b
open -a Simulator
xcrun simctl install "$simulator" "$root/.build/simulator.noindex/Build/Products/Debug-iphonesimulator/DrawMoar.app"
xcrun simctl launch "$simulator" "$DRAWMOAR_BUNDLE_ID"
