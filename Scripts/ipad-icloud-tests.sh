#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DERIVED_DATA=${SCRIPTWIDGET_DERIVED_DATA:-/tmp/scriptwidget-ipad-icloud-tests}
IPAD_DESTINATION=${SCRIPTWIDGET_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5)}
IPAD_UDID=${SCRIPTWIDGET_IPAD_UDID:-}
cd "$ROOT"

echo "Running deterministic iPad Runtime, cache, placeholder, and iCloud-state tests"
xcodebuild -quiet -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidgetRuntimeTests \
  -destination "$IPAD_DESTINATION" -derivedDataPath "$DERIVED_DATA/ipad" test

if [ -n "$IPAD_UDID" ]; then
  echo "Triggering Simulator iCloud sync on $IPAD_UDID"
  if ! xcrun simctl icloud_sync "$IPAD_UDID"; then
    echo "△ Simulator has no active iCloud account; deterministic iCloud tests passed, real sync was not exercised"
  fi
fi

if [ -n "${SCRIPTWIDGET_ICLOUD_DEVICE_DESTINATION:-}" ]; then
  echo "Running real iCloud container round-trip on the configured signed-in iPad"
  xcodebuild -quiet \
    -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidgetRuntimeTests \
    -destination "$SCRIPTWIDGET_ICLOUD_DEVICE_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA/icloud-device" \
    SCRIPTWIDGET_ICLOUD_INTEGRATION=1 \
    test -only-testing:ScriptWidgetRuntimeTests/ICloudContainerIntegrationTests
fi

if [ -n "${SCRIPTWIDGET_ICLOUD_WRITER_DESTINATION:-}" ] && [ -n "${SCRIPTWIDGET_ICLOUD_READER_DESTINATION:-}" ]; then
  TOKEN=${SCRIPTWIDGET_ICLOUD_SHARED_TOKEN:-$(date +%s)}
  echo "Writing cross-device iCloud probe $TOKEN"
  xcodebuild -quiet -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidgetRuntimeTests \
    -destination "$SCRIPTWIDGET_ICLOUD_WRITER_DESTINATION" -derivedDataPath "$DERIVED_DATA/icloud-writer" \
    SCRIPTWIDGET_ICLOUD_INTEGRATION=1 SCRIPTWIDGET_ICLOUD_ROLE=writer SCRIPTWIDGET_ICLOUD_SHARED_TOKEN="$TOKEN" \
    test -only-testing:ScriptWidgetRuntimeTests/ICloudContainerIntegrationTests/testCrossDeviceConvergenceWhenConfigured
  echo "Reading cross-device iCloud probe $TOKEN"
  xcodebuild -quiet -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidgetRuntimeTests \
    -destination "$SCRIPTWIDGET_ICLOUD_READER_DESTINATION" -derivedDataPath "$DERIVED_DATA/icloud-reader" \
    SCRIPTWIDGET_ICLOUD_INTEGRATION=1 SCRIPTWIDGET_ICLOUD_ROLE=reader SCRIPTWIDGET_ICLOUD_SHARED_TOKEN="$TOKEN" \
    test -only-testing:ScriptWidgetRuntimeTests/ICloudContainerIntegrationTests/testCrossDeviceConvergenceWhenConfigured
fi

echo "✓ iPad/iCloud automation completed"
