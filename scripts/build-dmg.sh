#!/usr/bin/env bash
#
# Build Time Tracker and package it into a distributable .dmg.
#
# Run on macOS with Xcode installed:
#     ./scripts/build-dmg.sh
#
# Output: dist/TimeTracker.dmg
#
# Optional environment variables:
#   DEVELOPER_ID   "Developer ID Application: Your Name (TEAMID)" to code-sign
#                  the app (needed before notarization / distribution to others).
#   SCHEME         Xcode scheme to build              (default: TimeTracker)
#   CONFIG         Build configuration                (default: Release)
#   VOL_NAME       Volume + .app display name         (default: "Time Tracker")
#
set -euo pipefail

# --- config -----------------------------------------------------------------
SCHEME="${SCHEME:-TimeTracker}"
CONFIG="${CONFIG:-Release}"
VOL_NAME="${VOL_NAME:-Time Tracker}"
PROJECT="TimeTracker.xcodeproj"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/TimeTracker.dmg"

# --- sanity checks ----------------------------------------------------------
command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found (install Xcode)."; exit 1; }
[ -d "$PROJECT" ] || { echo "error: $PROJECT not found. Run from the repo root."; exit 1; }

echo "==> Building $SCHEME ($CONFIG)…"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates \
  clean build \
  CODE_SIGN_STYLE=Automatic \
  | tail -20

APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$SCHEME.app"
[ -d "$APP_PATH" ] || { echo "error: built app not found at $APP_PATH"; exit 1; }
echo "==> Built: $APP_PATH"

# --- optional code signing --------------------------------------------------
if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> Code-signing with: $DEVELOPER_ID"
  codesign --force --deep --options runtime \
    --sign "$DEVELOPER_ID" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
  echo "==> No DEVELOPER_ID set — skipping Developer ID signing."
  echo "    The DMG will run on THIS Mac but Gatekeeper will block it on others."
fi

# --- stage and create the dmg ----------------------------------------------
echo "==> Staging disk image contents…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# Name the bundle by its display name so Finder shows "Time Tracker".
cp -R "$APP_PATH" "$STAGING/$VOL_NAME.app"
# Drag-to-install target.
ln -s /Applications "$STAGING/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

echo "==> Creating $DMG_PATH…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo
echo "Done: $DMG_PATH"
if [ -z "${DEVELOPER_ID:-}" ]; then
  echo
  echo "To distribute to other Macs without the 'unidentified developer' block,"
  echo "you'll need a paid Apple Developer account, then:"
  echo "  1. Re-run with DEVELOPER_ID set to your Developer ID Application identity."
  echo "  2. Notarize:  xcrun notarytool submit \"$DMG_PATH\" --apple-id <id> \\"
  echo "                  --team-id <TEAMID> --password <app-specific-pw> --wait"
  echo "  3. Staple:    xcrun stapler staple \"$DMG_PATH\""
fi
