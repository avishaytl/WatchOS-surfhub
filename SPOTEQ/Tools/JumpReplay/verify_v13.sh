#!/usr/bin/env bash
# Focused V13 safety gate:
#   1. adapter/unit E2E checks pass;
#   2. the 2026-07-11 zero-jump water/shore session stays at zero;
#   3. the prior positive session detects both absolute-barometer arcs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BINARY="$SCRIPT_DIR/.build/release/JumpReplay"
OUTPUT_DIR="$SCRIPT_DIR/.build/v13-regression-output"
ZERO_LOG="$ROOT_DIR/cloud_logs_20260711_latest_session/log_20260711_125607_91F05F7A.kslog"
POSITIVE_LOG="$ROOT_DIR/cloud_logs_20260707_latest/log_20260707_120725_1AD0512B.kslog"

for log in "$ZERO_LOG" "$POSITIVE_LOG"; do
    if [[ ! -f "$log" ]]; then
        echo "Missing V13 regression fixture: $log" >&2
        exit 2
    fi
done

cd "$SCRIPT_DIR"
swift build -c release
"$BINARY" --engine-e2e-selftest

"$BINARY" --engine v13 --output "$OUTPUT_DIR/zero" "$ZERO_LOG"
zero_count="$(jq '.jumps | length' "$OUTPUT_DIR/zero/log_20260711_125607_91F05F7A.actual.json")"
if [[ "$zero_count" -ne 0 ]]; then
    echo "V13 zero-jump regression failed: expected 0, got $zero_count" >&2
    exit 1
fi

"$BINARY" --engine v13 --output "$OUTPUT_DIR/positive" "$POSITIVE_LOG"
positive_count="$(jq '.jumps | length' "$OUTPUT_DIR/positive/log_20260707_120725_1AD0512B.actual.json")"
if [[ "$positive_count" -ne 2 ]]; then
    echo "V13 positive regression failed: expected 2, got $positive_count" >&2
    exit 1
fi

echo "V13 regression gate passed: zero-jump=0, prior-positive=2"
