#!/bin/sh
# Opt-in multi-turn AI quality run: several small conversations against a real
# provider, with what each turn changed, missed and cost. It uses provider
# tokens. Pass the key through the environment; never write it into a command.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
: "${ROCKY_OPENAI_APIKEY:?Set ROCKY_OPENAI_APIKEY to your provider key}"
: "${ROCKY_OPENAI_BASEURL:?Set ROCKY_OPENAI_BASEURL to your provider base URL}"
: "${ROCKY_OPENAI_MODEL:?Set ROCKY_OPENAI_MODEL to a model returned by your server}"
OUTPUT=${AI_CONVERSATION_QUALITY_OUTPUT:-"$ROOT/__Release/ai-conversation-quality/$(date +%Y%m%d-%H%M%S)"}
case "$OUTPUT" in /*) ;; *) echo 'AI_CONVERSATION_QUALITY_OUTPUT must be an absolute path' >&2; exit 2 ;; esac
export TEST_RUNNER_ROCKY_OPENAI_APIKEY="$ROCKY_OPENAI_APIKEY"
export TEST_RUNNER_ROCKY_OPENAI_BASEURL="$ROCKY_OPENAI_BASEURL"
export TEST_RUNNER_ROCKY_OPENAI_MODEL="$ROCKY_OPENAI_MODEL"
export TEST_RUNNER_AI_CONVERSATION_QUALITY=1
export TEST_RUNNER_AI_CONVERSATION_QUALITY_OUTPUT="$OUTPUT"
STATUS=0
xcodebuild -quiet -project macOS/ScriptWidgetMac.xcodeproj -scheme ScriptWidgetRuntimeTests \
  -destination 'platform=macOS' -derivedDataPath "${SCRIPTWIDGET_DERIVED_DATA:-/tmp/scriptwidget-ai-quality}" \
  -only-testing:ScriptWidgetRuntimeTests/AIConversationTests/testConversationQualityAgainstARealProviderWhenConfigured \
  CODE_SIGNING_ALLOWED=NO test || STATUS=$?
[ -f "$OUTPUT/report.md" ] && cat "$OUTPUT/report.md"
printf 'Multi-turn AI quality artifacts: %s\n' "$OUTPUT"
exit "$STATUS"
