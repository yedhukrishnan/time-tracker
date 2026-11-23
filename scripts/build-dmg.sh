#!/usr/bin/env bash
#
# Build Time Tracker and package it into a distributable .dmg, signed for
# distribution outside the Mac App Store (Developer ID).
#
# Run on macOS with Xcode installed:
#     ./scripts/build-dmg.sh
#
# Output: dist/TimeTracker.dmg  (signed; notarized + stapled if NOTARY_PROFILE set)
#         dist/appcast.xml      (Sparkle update feed; only for notarized builds)
#
# Prerequisites:
#   - A "Developer ID Application" certificate in your keychain
#     (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   - You're signed into your Apple ID in Xcode so it can manage the Developer ID
#     provisioning profile (needed because the app uses iCloud/Push entitlements).
#   - For notarization, save a credential once (then set NOTARY_PROFILE):
#       xcrun notarytool store-credentials <profile-name> \
#         --apple-id <your-apple-id> --team-id <TEAM_ID>
#
# Why archive+export (not plain `build`): `xcodebuild build` defaults to
# *development* signing, which on macOS needs your Mac registered as a device.
# The Developer ID export path uses a device-independent distribution profile.
#
# Optional environment variables:
#   TEAM_ID         Apple Developer Team ID         (default: T7U7ZSM986)
#   SCHEME          Xcode scheme                     (default: TimeTracker)
#   VOL_NAME        Volume + .app display name       (default: "Time Tracker")
#   NOTARY_PROFILE  notarytool keychain profile name; if set, the DMG is
#                   notarized and stapled automatically, and dist/appcast.xml
#                   is generated for in-app updates.
#   RELEASE_NOTES   Markdown file shown in the in-app update window (the same
#                   text as the GitHub release notes). Optional.
#   REPO            GitHub owner/repo hosting releases (default:
#                   yedhukrishnan/time-tracker).
#
# The appcast is signed with the Sparkle EdDSA key in the login Keychain
# (created once with generate_keys — see BUILDING.md).
#
set -euo pipefail

SCHEME="${SCHEME:-TimeTracker}"
VOL_NAME="${VOL_NAME:-Time Tracker}"
TEAM_ID="${TEAM_ID:-T7U7ZSM986}"
PROJECT="TimeTracker.xcodeproj"
REPO="${REPO:-yedhukrishnan/time-tracker}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/TimeTracker.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/TimeTracker.dmg"
APPCAST_PATH="$DIST_DIR/appcast.xml"
# Packages resolve here (not in DerivedData) so Sparkle's bin/ tools have a
# stable path. Outside build/, which is wiped each run.
PACKAGES_DIR="$ROOT/.build/SourcePackages"
SPARKLE_BIN="$PACKAGES_DIR/artifacts/sparkle/Sparkle/bin"

command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found (install Xcode)."; exit 1; }
[ -d "$PROJECT" ] || { echo "error: $PROJECT not found. Run from the repo root."; exit 1; }

# --- 1. Archive (Release) --------------------------------------------------
echo "==> Archiving $SCHEME..."
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$PACKAGES_DIR" \
  -allowProvisioningUpdates \
  archive

# --- 2. Export with Developer ID ------------------------------------------
# Signs with your Developer ID Application cert and embeds a Developer ID
# provisioning profile that authorizes the iCloud/Push entitlements.
echo "==> Exporting Developer ID build..."
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
echo "==> Staging disk image..."
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/$VOL_NAME.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$APPCAST_PATH"
echo "==> Creating $DMG_PATH..."
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

# --- 4. Notarize + staple (if a credential profile is provided) ------------
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (profile: $NOTARY_PROFILE)... this can take a few minutes"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling the ticket onto the DMG..."
  xcrun stapler staple "$DMG_PATH"
  echo "==> Verifying Gatekeeper acceptance..."
  spctl -a -vvv -t install "$DMG_PATH" || true

  # --- 5. Sparkle appcast (in-app updates) ---------------------------------
  # Sign the *stapled* DMG (stapling changes its bytes) and write the feed the
  # app reads from the latest GitHub release.
  echo "==> Generating appcast..."
  [ -x "$SPARKLE_BIN/sign_update" ] || { echo "error: Sparkle tools not found at $SPARKLE_BIN"; exit 1; }
  INFO="$APP_PATH/Contents/Info.plist"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
  MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
  SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG_PATH")"   # sparkle:edSignature="…" length="…"
  NOTES_HTML="<p>Time Tracker $VERSION</p>"
  if [ -n "${RELEASE_NOTES:-}" ]; then
    command -v pandoc >/dev/null || { echo "error: pandoc is needed to render RELEASE_NOTES (brew install pandoc)"; exit 1; }
    NOTES_HTML="$(pandoc -f gfm -t html "$RELEASE_NOTES")"
  fi
  cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Time Tracker</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/TimeTracker.dmg"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
  xmllint --noout "$APPCAST_PATH"
  echo
  echo "Done (signed + notarized + stapled): $DMG_PATH"
  echo "This DMG opens cleanly on other Macs."
  echo "Appcast: $APPCAST_PATH — attach it AND the DMG to the v$VERSION release."
else
  echo
  echo "Done (signed, NOT notarized): $DMG_PATH"
  echo "It runs on THIS Mac, but other Macs will show a Gatekeeper warning."
  echo
  echo "To notarize automatically: save a credential once, then re-run:"
  echo "  xcrun notarytool store-credentials timetracker \\"
  echo "    --apple-id <your-apple-id> --team-id $TEAM_ID"
  echo "  NOTARY_PROFILE=timetracker ./scripts/build-dmg.sh"
fi
