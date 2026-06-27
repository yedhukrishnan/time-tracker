#!/usr/bin/env bash
#
# Build Time Tracker and package it into a distributable .dmg, signed for
# distribution outside the Mac App Store (Developer ID).
#
# Run on macOS with Xcode installed:
#     ./scripts/build-dmg.sh
#
# Output: dist/TimeTracker.dmg  (sign-then-notarize; notarize commands printed)
#
# Prerequisites:
#   - A "Developer ID Application" certificate in your keychain
#     (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application).
#   - You're signed into your Apple ID in Xcode so it can manage the Developer ID
#     provisioning profile (needed because the app uses iCloud/Push entitlements).
#
# Why archive+export (not plain `build`): `xcodebuild build` defaults to
# *development* signing, which on macOS needs your Mac registered as a device.
# The Developer ID export path uses a device-independent distribution profile.
#
# Optional environment variables:
#   TEAM_ID    Apple Developer Team ID            (default: T7U7ZSM986)
#   SCHEME     Xcode scheme                        (default: TimeTracker)
#   VOL_NAME   Volume + .app display name          (default: "Time Tracker")
#
set -euo pipefail

SCHEME="${SCHEME:-TimeTracker}"
VOL_NAME="${VOL_NAME:-Time Tracker}"
TEAM_ID="${TEAM_ID:-T7U7ZSM986}"
PROJECT="TimeTracker.xcodeproj"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/TimeTracker.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/TimeTracker.dmg"

command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found (install Xcode)."; exit 1; }
[ -d "$PROJECT" ] || { echo "error: $PROJECT not found. Run from the repo root."; exit 1; }

# --- 1. Archive (Release) --------------------------------------------------
echo "==> Archiving $SCHEME…"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive

# --- 2. Export with Developer ID ------------------------------------------
# Signs with your Developer ID Application cert and embeds a Developer ID
# provisioning profile that authorizes the iCloud/Push entitlements.
echo "==> Exporting Developer ID build…"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates

APP_PATH="$EXPORT_DIR/$SCHEME.app"
[ -d "$APP_PATH" ] || { echo "error: exported app not found at $APP_PATH"; exit 1; }
echo "==> Exported (Developer ID signed): $APP_PATH"

# --- 3. Package the .dmg ---------------------------------------------------
echo "==> Staging disk image…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/$VOL_NAME.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
echo "==> Creating $DMG_PATH…"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

echo
echo "Done (signed, not yet notarized): $DMG_PATH"
echo
echo "Notarize and staple so it opens cleanly on other Macs:"
echo "  xcrun notarytool submit \"$DMG_PATH\" --keychain-profile <profile> --wait"
echo "  xcrun stapler staple \"$DMG_PATH\""
echo "Then verify:"
echo "  spctl -a -vvv -t install \"$DMG_PATH\""
