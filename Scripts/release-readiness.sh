#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DERIVED_DATA=${SCRIPTWIDGET_DERIVED_DATA:-/tmp/scriptwidget-release-readiness}
cd "$ROOT"

node Scripts/validate-release.mjs
(cd Editor/editorfe && npm test && npm run release)
git diff --exit-code -- \
  iOS/ScriptWidget/View/CodeEditor/MirrorEditor/StudioEditor.bundle \
  macOS/ScriptWidgetMac/StudioEditor.bundle

if [ "${SCRIPTWIDGET_SKIP_XCODE:-0}" != "1" ]; then
  xcodebuild -quiet -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetRuntimeTests \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA/macos-tests" \
    CODE_SIGNING_ALLOWED=NO test
  xcodebuild -quiet -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetMac \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA/macos-app" \
    CODE_SIGNING_ALLOWED=NO build
  xcodebuild -quiet -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidget \
    -sdk iphonesimulator -derivedDataPath "$DERIVED_DATA/ios-app" \
    CODE_SIGNING_ALLOWED=NO build
  xcodebuild -quiet -project iOS/ScriptWidget.xcodeproj -scheme ScriptWidgetRuntimeTests \
    -destination "${SCRIPTWIDGET_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" \
    -derivedDataPath "$DERIVED_DATA/ios-tests" test
fi

echo "✓ ScriptWidget release-readiness checks passed"
