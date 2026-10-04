#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/scriptwidget-link-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc -module-cache-path "$TEST_DIR/module-cache" \
  "$ROOT/macOS/ScriptWidgetMac/App/AppDelegate.swift" \
  "$ROOT/Shared/ScriptWidgetRuntime/Widget/Runtime/DeepLinkDefine.swift" \
  "$ROOT/Tests/MacWidgetLinkTests/main.swift" \
  -o "$TEST_DIR/widget-link-tests"
"$TEST_DIR/widget-link-tests"
