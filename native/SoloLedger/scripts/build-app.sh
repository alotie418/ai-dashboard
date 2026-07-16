#!/bin/bash
# Assemble a runnable, ad-hoc-signed .app bundle (App Sandbox) from the SwiftPM
# build for local smoke testing. Production MAS packaging (a real Xcode app
# target + Developer ID / MAS signing) is a later phase — see the plan doc.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$HERE/build/SoloLedger.app"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG" --package-path "$HERE"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$HERE" --show-bin-path)"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SoloLedger" "$APP/Contents/MacOS/SoloLedger"
cp "$HERE/Packaging/Info.plist" "$APP/Contents/Info.plist"

# Localization resource bundle -> Contents/Resources (the conventional macOS
# location that Localizer loads via Bundle.main.resourceURL). Do NOT place it at
# the .app root. It MUST exist — fail loudly if the build didn't produce it.
if [ ! -d "$BIN_DIR/SoloLedger_SoloLedger.bundle" ]; then
  echo "✗ resource bundle SoloLedger_SoloLedger.bundle not found in $BIN_DIR" >&2
  exit 1
fi
cp -R "$BIN_DIR/SoloLedger_SoloLedger.bundle" "$APP/Contents/Resources/"

echo "▸ ad-hoc codesigning with App Sandbox entitlements"
codesign --force --sign - --entitlements "$HERE/Packaging/SoloLedger.entitlements" --deep "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null | grep -q "app-sandbox" \
  && echo "  sandbox entitlement present ✓"

echo "▸ verifying packaged resources load (regression guard for the Bundle.module launch crash)"
"$APP/Contents/MacOS/SoloLedger" --check-resources

echo "✅ built $APP"
echo "   run GUI:      open \"$APP\""
echo "   run selftest: \"$APP/Contents/MacOS/SoloLedger\" --self-test"
