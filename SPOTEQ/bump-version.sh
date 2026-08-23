#!/bin/bash
# ──────────────────────────────────────────────────
#  bump-version.sh — Single-command version bumping
#  for the SPOTEQ Xcode project.
#
#  Usage:
#    ./bump-version.sh                  # show current version
#    ./bump-version.sh 1.2              # set marketing version
#    ./bump-version.sh 1.2 5            # set version + build
#    ./bump-version.sh --bump-build     # increment build number by 1
# ──────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
XCCONFIG="$SCRIPT_DIR/Config.xcconfig"

if [ ! -f "$XCCONFIG" ]; then
  echo "❌  Config.xcconfig not found at $XCCONFIG"
  exit 1
fi

current_version=$(grep '^MARKETING_VERSION' "$XCCONFIG" | sed 's/.*= *//')
current_build=$(grep '^CURRENT_PROJECT_VERSION' "$XCCONFIG" | sed 's/.*= *//')

# ── No arguments: show current ──
if [ $# -eq 0 ]; then
  echo "📱  SPOTEQ v${current_version} (${current_build})"
  exit 0
fi

# ── --bump-build: increment build number ──
if [ "$1" = "--bump-build" ]; then
  new_build=$((current_build + 1))
  sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${new_build}/" "$XCCONFIG"
  echo "📱  SPOTEQ v${current_version} (${current_build}) → v${current_version} (${new_build})"
  exit 0
fi

# ── Positional args: version [build] ──
new_version="$1"
new_build="${2:-$current_build}"

sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${new_version}/" "$XCCONFIG"
sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${new_build}/" "$XCCONFIG"

echo "📱  SPOTEQ v${current_version} (${current_build}) → v${new_version} (${new_build})"
