#!/usr/bin/env bash
# Surfr reference gate for the 2026-06-12 screenshot.
#
# Usage:
#   ./surfr_check.sh
#   ./surfr_check.sh v8 ../../../docs/log2.json
#   ./surfr_check.sh --engine v10 --log ../../../docs/log2.json --allow-extra

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ENGINE="v8"
LOG="$SCRIPT_DIR/../../../docs/log2.json"
OUTPUT_DIR="$SCRIPT_DIR/output_surfr"
EXTRA_FLAGS=()
POSITIONAL=()

usage() {
    cat <<'EOF'
Usage:
  ./surfr_check.sh [engine] [log]
  ./surfr_check.sh --engine <v7|v8|v10> --log <path> [options]

Options:
  --engine <v7|v8|v10>          Engine to replay (default: v8)
  --log <path>                  Log file to replay (default: ../../../docs/log2.json)
  --output <dir>                Output directory (default: ./output_surfr)
  --allow-extra                 Ignore accepted jumps outside the 4 Surfr rows
  --no-gps                      Replay without GPS/speed updates
  --no-throws                   v8 only: disable ballistic throw path
  --time-tolerance <sec>        Default: 3.0
  --height-tolerance <m>        Default: 0.75
  --airtime-tolerance <sec>     Default: 0.50
  --distance-tolerance <m>      Default: 10.0
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)
            ENGINE="$2"
            shift 2
            ;;
        --log)
            LOG="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --allow-extra)
            EXTRA_FLAGS+=("--allow-surfr-extra-jumps")
            shift
            ;;
        --no-gps)
            EXTRA_FLAGS+=("--no-gps")
            shift
            ;;
        --no-throws)
            EXTRA_FLAGS+=("--no-throws")
            shift
            ;;
        --time-tolerance)
            EXTRA_FLAGS+=("--surfr-time-tolerance" "$2")
            shift 2
            ;;
        --height-tolerance)
            EXTRA_FLAGS+=("--surfr-height-tolerance" "$2")
            shift 2
            ;;
        --airtime-tolerance)
            EXTRA_FLAGS+=("--surfr-airtime-tolerance" "$2")
            shift 2
            ;;
        --distance-tolerance)
            EXTRA_FLAGS+=("--surfr-distance-tolerance" "$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ "${#POSITIONAL[@]}" -gt 2 ]]; then
    echo "Unexpected arguments: ${POSITIONAL[*]}" >&2
    usage >&2
    exit 2
fi
if [[ "${#POSITIONAL[@]}" -ge 1 ]]; then
    ENGINE="${POSITIONAL[0]}"
fi
if [[ "${#POSITIONAL[@]}" -ge 2 ]]; then
    LOG="${POSITIONAL[1]}"
fi

case "$ENGINE" in
    v7|v8|v10) ;;
    *)
        echo "Unsupported engine: $ENGINE" >&2
        exit 2
        ;;
esac

if [[ ! -f "$LOG" ]]; then
    echo "Log file not found: $LOG" >&2
    exit 2
fi

swift build >/dev/null

BINARY="$SCRIPT_DIR/.build/debug/JumpReplay"
"$BINARY" \
    --engine "$ENGINE" \
    --output "$OUTPUT_DIR/$ENGINE" \
    --surfr \
    --require-surfr-reference \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
    "$LOG"
