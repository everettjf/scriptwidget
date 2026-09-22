#!/bin/sh
# Opt-in, bounded live generation using synthetic offline prompts.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ -z "${AI_QUALITY_REPLAY:-}" ]; then
  : "${ROCKY_OPENAI_APIKEY:?Set ROCKY_OPENAI_APIKEY to your provider key}"
  : "${ROCKY_OPENAI_BASEURL:?Set ROCKY_OPENAI_BASEURL to your provider base URL}"
  : "${ROCKY_OPENAI_MODEL:?Set ROCKY_OPENAI_MODEL to a model returned by your server}"
fi
OUTPUT=${AI_QUALITY_OUTPUT:-"$ROOT/__Release/ai-quality/$(date +%Y%m%d-%H%M%S)"}
case "$OUTPUT" in /*) ;; *) echo 'AI_QUALITY_OUTPUT must be an absolute path' >&2; exit 2 ;; esac
export TEST_RUNNER_ROCKY_OPENAI_APIKEY="${ROCKY_OPENAI_APIKEY:-}"
export TEST_RUNNER_ROCKY_OPENAI_BASEURL="${ROCKY_OPENAI_BASEURL:-http://localhost}"
export TEST_RUNNER_ROCKY_OPENAI_MODEL="${ROCKY_OPENAI_MODEL:-replay}"
export TEST_RUNNER_AI_QUALITY=1
export TEST_RUNNER_AI_QUALITY_ATTEMPTS=${AI_QUALITY_ATTEMPTS:-2}
export TEST_RUNNER_AI_QUALITY_OUTPUT="$OUTPUT"
if [ -n "${AI_QUALITY_REPLAY:-}" ]; then
  export TEST_RUNNER_AI_QUALITY_REPLAY="$AI_QUALITY_REPLAY"
else
  unset TEST_RUNNER_AI_QUALITY_REPLAY
fi
STATUS=0
xcodebuild -quiet -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetRuntimeTests \
  -destination 'platform=macOS' -derivedDataPath "${SCRIPTWIDGET_DERIVED_DATA:-/tmp/scriptwidget-ai-quality}" \
  -only-testing:ScriptWidgetRuntimeTests/AIGenerationTests/testWidgetQualityMatrix \
  CODE_SIGNING_ALLOWED=NO test || STATUS=$?
if [ -f "$OUTPUT/quality.json" ]; then
  swift Scripts/ai-quality-images.swift "$OUTPUT"
  python3 Scripts/ai-quality-report.py "$OUTPUT"
fi
printf 'AI quality artifacts: %s\n' "$OUTPUT"
exit "$STATUS"
