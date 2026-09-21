#!/bin/bash
# Build Fleet-<version>.dmg.
#
#   ./make-dmg.sh                      ad-hoc signed — runs on THIS Mac only
#   FLEET_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-dmg.sh
#                                      signed with hardened runtime — runs anywhere once notarized
#   FLEET_NOTARY_PROFILE=fleet-notary  ...and also notarize + staple. Create the profile once with:
#       xcrun notarytool store-credentials fleet-notary --apple-id you@example.com \
#             --team-id TEAMID --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
DMG="Fleet-$VERSION.dmg"
SIGN_ID=${FLEET_SIGN_ID:-}
PROFILE=${FLEET_NOTARY_PROFILE:-}

./build-app.sh >/dev/null
if [ -n "$SIGN_ID" ]; then
  echo "▸ signing with: $SIGN_ID (hardened runtime)"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" Fleet.app
  codesign --verify --deep --strict Fleet.app
else
  echo "▸ no FLEET_SIGN_ID — keeping the ad-hoc signature (this Mac only)"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R Fleet.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Fleet $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ -n "$SIGN_ID" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  if [ -n "$PROFILE" ]; then
    echo "▸ notarizing (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
  else
    echo "▸ signed but NOT notarized — Gatekeeper will still warn. Set FLEET_NOTARY_PROFILE."
  fi
fi

hdiutil verify "$DMG" >/dev/null && echo "▸ built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
