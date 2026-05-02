#!/usr/bin/env bash
# Boots a simulator, builds the wayfind app, runs ScreenshotUITests, and
# writes PNGs to screenshots/output/ (see screenshots/README.md).
#
# Usage:
#   chmod +x screenshots/capture_screenshots.sh   # once
#   ./screenshots/capture_screenshots.sh
#
# Optional env:
#   SCHEME=wayfind SIM_NAME='iPhone 16' SIM_OS='18.1'
#   DESTINATION='platform=iOS Simulator,id=<UDID>'  # overrides SIM_NAME/SIM_OS

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="${SCHEME:-wayfind}"
PROJECT="$REPO_ROOT/wayfind.xcodeproj"
OUTPUT_DIR="${SCREENSHOTS_DIR:-$REPO_ROOT/screenshots/output}"
mkdir -p "$OUTPUT_DIR"
export SCREENSHOTS_DIR="$OUTPUT_DIR"

if [[ -n "${DESTINATION:-}" ]]; then
  DEST="$DESTINATION"
else
  SIM_NAME="${SIM_NAME:-iPhone 16}"
  SIM_OS="${SIM_OS:-18.1}"
  DEST="platform=iOS Simulator,name=${SIM_NAME},OS=${SIM_OS}"
fi

echo "==> Destination: $DEST"
echo "==> Screenshots: $OUTPUT_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DEST" \
  -only-testing:wayfindUITests/ScreenshotUITests/testCaptureScreens \
  test

echo "==> Done. PNGs in $OUTPUT_DIR"
