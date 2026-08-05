#!/bin/sh

set -eu

npm run build

IOS_BUNDLE="../../iOS/ScriptWidget/View/CodeEditor/MirrorEditor/StudioEditor.bundle"
MACOS_BUNDLE="../../macOS/ScriptWidgetMac/StudioEditor.bundle"

rm -rf "$IOS_BUNDLE" "$MACOS_BUNDLE"
mkdir -p "$IOS_BUNDLE" "$MACOS_BUNDLE"
cp -R dist/. "$IOS_BUNDLE/"
cp -R dist/. "$MACOS_BUNDLE/"
