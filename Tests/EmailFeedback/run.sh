#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/feedback-email-tests.XXXXXX")
trap 'rm -rf "$OUTPUT"' EXIT
swiftc "$ROOT/Shared/AppFeedback/FeedbackEmail.swift" "$ROOT/Tests/EmailFeedback/main.swift" -o "$OUTPUT/tests"
"$OUTPUT/tests"
