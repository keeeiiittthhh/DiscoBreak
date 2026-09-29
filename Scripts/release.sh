#!/bin/bash
# Builds a shippable DiscoBreak.dmg.
#
#   ./Scripts/release.sh
#
# Signing is driven entirely by environment variables, so this script works
# today (ad-hoc, for you and anyone willing to right-click → Open) and works
# unchanged the day the Apple Developer Program membership exists:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"   # real signature
#   NOTARY_PROFILE="discobreak"                                   # xcrun notarytool profile
#
# Store the notary profile once with:
#   xcrun notarytool store-credentials discobreak \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/DiscoBreak.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
DMG="$ROOT/build/DiscoBreak-$VERSION.dmg"
STAGE="$ROOT/build/dmg"

"$ROOT/Scripts/bundle.sh" release

# --- sign ------------------------------------------------------------------
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "Signing with: $DEVELOPER_ID"
  codesign --force --options runtime --timestamp \
           --entitlements "$ROOT/DiscoBreak.entitlements" \
           --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "No DEVELOPER_ID set — ad-hoc signature only."
  echo "Gatekeeper will warn on other Macs; they must right-click → Open once."
fi

# --- dmg -------------------------------------------------------------------
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "DiscoBreak" -srcfolder "$STAGE" \
               -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# --- notarize --------------------------------------------------------------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "No NOTARY_PROFILE set — skipping notarization."
fi

echo
echo "Built $DMG  ($(du -h "$DMG" | cut -f1))"
