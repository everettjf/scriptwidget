# ScriptWidget App Store screenshots

Source images are real Xcode 27.0 simulator captures of ScriptWidget's current UI. The screenshot simulator's local library includes templates copied from the app's bundled `Script.bundle`. For the code editor slide, `Daily Agenda` was edited only in the simulator's local copy into a short, valid JSX widget that renders a live preview; the bundled template in the repository was not changed. The gallery, code editor, and API reference are opened with DEBUG-only launch arguments (`-storeScreenshotGallery`, `-storeScreenshotCode`, `-storeScreenshotAPIs`). No application UI was drawn or invented for these store images.

The four iPhone and four iPad slides cover template selection, the widget list, code plus preview, and the built-in API reference. The backgrounds use coral, blue, mint, and warm yellow drawn from the app icon's palette. Exported sizes are under `exports/ios/iphone/` and `exports/ios/ipad/`; captured source screens are under `public/screenshots/apple/`.

The current App Store version was historically Ready for Distribution; verify live status in App Store Connect before creating the next minor version. Do not upload these into any version that is already in review. Final Submit for Review remains manual.
