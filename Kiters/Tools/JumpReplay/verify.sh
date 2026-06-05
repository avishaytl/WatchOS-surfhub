#!/usr/bin/env bash
# verify.sh — regression gate for JumpDetector
#
# Usage:
#   ./verify.sh            # compare all logs against expected baselines (exit 1 on mismatch)
#   ./verify.sh --bless    # overwrite expected baselines with current output
#   ./verify.sh --verbose  # also print per-sample events

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/../../logs"
cd "$SCRIPT_DIR"

# ── Parse flags ──────────────────────────────────────────────────────────────
MODE_FLAG="--compare"
EXTRA_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --bless)   MODE_FLAG="--bless" ;;
        --verbose) EXTRA_FLAGS+=("--verbose") ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# ── Build ─────────────────────────────────────────────────────────────────────
echo "=== Building JumpReplay ==="
swift build 2>&1 | grep -E "error:|warning:|Build complete" || true
echo ""

BINARY="$SCRIPT_DIR/.build/debug/JumpReplay"

# ── Log files to test ─────────────────────────────────────────────────────────
LOGS=(
    "$LOGS_DIR/kitesurf_realistic_log.csv"
    "$LOGS_DIR/kitesurf_ultra_realistic_log.csv"
    "$LOGS_DIR/kitesurf_ultra_realistic_log.json"
    "$LOGS_DIR/kitesurf_extreme_failure_case_log.json"
    "$LOGS_DIR/kitesurf_jump_log_synthetic.csv"
    "$LOGS_DIR/kitesurf_session_5min_3jumps.json"
)

# Also pick up any on-device logs exported from the watch (log_*.csv)
while IFS= read -r -d '' f; do
    LOGS+=("$f")
done < <(find "$LOGS_DIR" -maxdepth 1 -name "log_*.csv" -print0 2>/dev/null || true)

# ── Run ───────────────────────────────────────────────────────────────────────
if [[ "$MODE_FLAG" == "--bless" ]]; then
    echo "=== Blessing baselines ==="
else
    echo "=== Running regression compare ==="
fi

PASS=0
FAIL=0
SKIP=0

for log in "${LOGS[@]}"; do
    name="$(basename "$log")"
    stem="${name%.*}"
    expected="$SCRIPT_DIR/expected/${stem}.expected.json"

    # For --compare, skip logs that have no expected baseline yet (e.g. new device exports)
    if [[ "$MODE_FLAG" == "--compare" && ! -f "$expected" ]]; then
        echo "  ~  $name  (no baseline — run with --bless to create one)"
        ((SKIP++))
        continue
    fi

    if "$BINARY" "$MODE_FLAG" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$log" 2>/dev/null; then
        echo "  ✓  $name"
        ((PASS++))
    else
        echo "  ✗  $name"
        ((FAIL++))
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo ""

if [[ "$MODE_FLAG" == "--bless" ]]; then
    echo "Baselines updated. Commit the expected/ directory."
    exit 0
fi

[[ "$FAIL" -eq 0 ]]
