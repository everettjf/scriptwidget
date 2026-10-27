#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DERIVED_DATA=${SCRIPTWIDGET_DERIVED_DATA:-/tmp/scriptwidget-release-readiness}
cd "$ROOT"

node Scripts/validate-release.mjs
node Scripts/sync-gallery-templates.mjs
node --test Scripts/tests/gallery-sync.test.mjs
node Scripts/validate-doc-links.mjs
(cd Editor/editorfe && npm test && npm run release)
(cd Web/preview-engine && npm test)
(cd Web/studio && npm test && npm run build)
if node -e 'import("./Web/preview-engine/scripts/lib/chrome.mjs").then((m) => process.exit(m.findChrome() ? 0 : 1))'; then
  node Web/studio/scripts/onboarding-smoke.ts
  node Web/studio/scripts/smoke.ts
  node Web/studio/scripts/validation-smoke.ts
  node Web/studio/scripts/preview-handoff-smoke.ts
  node Web/studio/scripts/layout-smoke.ts
  node Web/studio/scripts/assets-smoke.ts
  node Web/studio/scripts/persistence-smoke.ts
  node Web/studio/scripts/material-smoke.ts
  node Web/studio/scripts/wallpaper-crop-smoke.ts
  node Web/studio/scripts/wallpaper-smoke.ts
  node Web/preview-engine/scripts/gif-smoke.mjs
  node Web/preview-engine/scripts/animation-smoke.mjs
else
  echo "Skipping Web Studio browser smoke test: Chrome not found"
fi
git diff --exit-code -- \
  iOS/ScriptWidget/View/CodeEditor/MirrorEditor/StudioEditor.bundle \
  macOS/ScriptWidgetMac/StudioEditor.bundle

if [ "${SCRIPTWIDGET_SKIP_XCODE:-0}" != "1" ]; then
  node Scripts/test-runtime-delivery.mjs
  node Scripts/test-service-authorization.mjs
  node Scripts/test-storage-atomic.mjs
  node Scripts/test-icloud-json.mjs
  node Scripts/test-system-services.mjs
  node Scripts/test-storage-files.mjs
  sh Scripts/macos-widget-link-tests.sh
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
