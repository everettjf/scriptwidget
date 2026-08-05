#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DERIVED_DATA=${SCRIPTWIDGET_DERIVED_DATA:-/tmp/scriptwidget-device-matrix}
IPHONE_DESTINATION=${SCRIPTWIDGET_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17}
IPAD_DESTINATION=${SCRIPTWIDGET_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad (A16)}
cd "$ROOT"

echo "Available Apple devices:"
xcrun xctrace list devices

for destination in "$IPHONE_DESTINATION" "$IPAD_DESTINATION"; do
  echo "Building iOS app for $destination"
  xcodebuild -quiet -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidget \
    -destination "$destination" -derivedDataPath "$DERIVED_DATA/$(echo "$destination" | tr ' ,()=' '_____')" \
    build
done

echo "Building macOS app"
xcodebuild -quiet -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetMac \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA/macos" build

echo "✓ automated build matrix passed; complete the physical-device interactions in docs/release-readiness.md"
