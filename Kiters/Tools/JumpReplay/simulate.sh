#!/usr/bin/env bash
# simulate.sh — run a real sensor log through the V14/V15 jump-detection
# simulation from the terminal. This drives the exact watch engine code
# (JumpEngineV14 / JumpEngineV15, via WatchSources/ symlinks) offline — no
# watch, no simulator, no synthetic sensors.
#
# Usage:
#   ./simulate.sh v14 path/to/log.kslog
#   ./simulate.sh v15 path/to/log.kslog
#   ./simulate.sh both path/to/log.kslog          # run V14 and V15 and diff them
#   ./simulate.sh v14 path/to/log.kslog --verbose  # extra flags pass through to JumpReplay
#
# Output JSON lands in output/<engine>/<logname>.actual.json (see JumpReplay
# --help for every available flag: --bless / --compare / --evaluate / etc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    echo "Usage: $0 <v14|v15|both> <log-file> [extra JumpReplay flags...]" >&2
    echo "  e.g.  $0 v14 ../../../cloud_logs_20260720_latest/log_20260720_131931_3E5ACB90.kslog" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage

ENGINE="$1"; shift
LOG="$1"; shift

case "$ENGINE" in
    v14|v15|both) ;;
    *) echo "Unsupported engine: $ENGINE (use v14, v15, or both)" >&2; exit 2 ;;
esac

[[ -f "$LOG" ]] || { echo "Log file not found: $LOG" >&2; exit 2; }

echo "=== Building JumpReplay (release) ==="
swift build -c release 2>&1 | grep -E "error:|warning:|Build complete" || true
echo ""

BINARY="$SCRIPT_DIR/.build/release/JumpReplay"

run_one() {
    local engine="$1"; shift
    local out_dir="$SCRIPT_DIR/output/$engine"
    echo "─────────────────────────────────────────────────────"
    echo "Engine: $engine   Log: $(basename "$LOG")"
    echo "─────────────────────────────────────────────────────"
    "$BINARY" --engine "$engine" --output "$out_dir" "$@" "$LOG"
    echo ""
    echo "→ JSON: $out_dir/$(basename "${LOG%.*}").actual.json"
    echo ""
}

if [[ "$ENGINE" == "both" ]]; then
    run_one v14 "$@"
    run_one v15 "$@"
else
    run_one "$ENGINE" "$@"
fi
