#!/bin/bash
# Assemble Fleet.app from the SwiftPM build. Ad-hoc signed (no Apple account
# needed for local use). For distribution, sign + notarize with a Developer ID.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="Fleet.app"
BIN_NAME="FleetApp"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"
BUILD_DIR=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/$BIN_NAME" "$APP/Contents/MacOS/Fleet"

# SwiftTerm ships a resource bundle — carry it next to the binary
for b in "$BUILD_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" && echo "▸ bundled $(basename "$b")"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Fleet</string>
  <key>CFBundleDisplayName</key><string>Fleet</string>
  <key>CFBundleIdentifier</key><string>sh.fleet.cockpit</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Fleet</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 bishesh</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || echo "▸ (codesign skipped)"
echo "▸ built $APP"
echo "  open $APP    # or: ./$APP/Contents/MacOS/Fleet for console output"
