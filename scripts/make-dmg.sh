#!/usr/bin/env bash
# Build a Gatekeeper-clean TinyFire.dmg:
#   archive → Developer ID export (cloud-managed) → notarize upload → staple → DMG
# Requires: paid Apple Developer team signed into Xcode (Xcode uses Grand Slam for notary).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/TinyFire-dmg-build"
DIST="$ROOT/dist"
EXPORT_OPTS="$ROOT/scripts/ExportOptions-DeveloperID.plist"
EXPORT_OPTS_UPLOAD="$WORK/ExportOptions-Upload.plist"
APP_NAME="TinyFire"
PRODUCT_APP="tinyFire.app"
TEAM_ID="J349NAK4T7"

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"

echo "==> Reading version..."
MARKETING_VERSION="$(
  cd "$ROOT" && xcodebuild -scheme tinyFire -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION / {print $2; exit}' | tr -d '[:space:]'
)"
VERSION="${MARKETING_VERSION:-1.0}"
DMG_NAME="TinyFire-${VERSION}.dmg"

# Embed private update endpoint into the source tree before archive (gitignored file).
# Cloud-managed Developer ID cannot re-sign after export, so this must be present pre-archive.
ENDPOINT_PLIST="$ROOT/tinyFire/UpdateEndpoint.plist"
if [[ -f "$ENDPOINT_PLIST" ]]; then
  echo "==> UpdateEndpoint.plist present (will be archived if Xcode copies it / already in Resources)."
fi

echo "==> Archiving Release..."
cd "$ROOT"
xcodebuild \
  -scheme tinyFire \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$WORK/TinyFire.xcarchive" \
  -derivedDataPath "$WORK/DerivedData" \
  archive \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  ENABLE_HARDENED_RUNTIME=YES

ARCHIVE_APP="$WORK/TinyFire.xcarchive/Products/Applications/$PRODUCT_APP"
test -d "$ARCHIVE_APP"

# If endpoint exists but wasn't copied into the archive, inject before export.
# Export will Developer-ID-sign the final payload (cloud managed).
if [[ -f "$ENDPOINT_PLIST" && ! -f "$ARCHIVE_APP/Contents/Resources/UpdateEndpoint.plist" ]]; then
  echo "==> Injecting UpdateEndpoint.plist into archive before export..."
  mkdir -p "$ARCHIVE_APP/Contents/Resources"
  cp "$ENDPOINT_PLIST" "$ARCHIVE_APP/Contents/Resources/UpdateEndpoint.plist"
fi

BUILT_VER="$(defaults read "$ARCHIVE_APP/Contents/Info" CFBundleShortVersionString)"
echo "==> Archived app version: ${BUILT_VER}"
if [[ "$BUILT_VER" != "$VERSION" ]]; then
  echo "ERROR: expected marketing version ${VERSION}, got ${BUILT_VER}" >&2
  exit 1
fi

echo "==> Exporting Developer ID (cloud-managed signing)..."
mkdir -p "$WORK/export"
xcodebuild -exportArchive \
  -archivePath "$WORK/TinyFire.xcarchive" \
  -exportPath "$WORK/export" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates

EXPORTED_APP="$WORK/export/$PRODUCT_APP"
test -d "$EXPORTED_APP"

echo "==> Uploading for notarization (Xcode Apple ID session)..."
cat > "$EXPORT_OPTS_UPLOAD" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>upload</string>
</dict>
</plist>
PLIST

mkdir -p "$WORK/export-upload"
xcodebuild -exportArchive \
  -archivePath "$WORK/TinyFire.xcarchive" \
  -exportPath "$WORK/export-upload" \
  -exportOptionsPlist "$EXPORT_OPTS_UPLOAD" \
  -allowProvisioningUpdates

echo "==> Waiting for Apple notarization ticket, then stapling..."
# Poll stapler until the ticket is available (same CDHash as exported app).
STAPLE_OK=0
for i in $(seq 1 60); do
  if xcrun stapler staple "$EXPORTED_APP" 2>/dev/null; then
    STAPLE_OK=1
    break
  fi
  echo "    ... ticket not ready yet (attempt ${i}/60), sleep 15s"
  sleep 15
done
if [[ "$STAPLE_OK" -ne 1 ]]; then
  echo "ERROR: notarization ticket never became staplable. Check Xcode Organizer / notary history." >&2
  exit 1
fi
xcrun stapler validate "$EXPORTED_APP"
spctl -a -vv -t install "$EXPORTED_APP"

echo "==> Staging DMG..."
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
ditto "$EXPORTED_APP" "$STAGE/${APP_NAME}.app"
ln -sf /Applications "$STAGE/Applications"

echo "==> Creating ${DMG_NAME}..."
rm -f "$DIST/$DMG_NAME"
hdiutil create \
  -volname "TinyFire" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DIST/$DMG_NAME"

rm -rf "$DIST/${APP_NAME}.app"
ditto "$STAGE/${APP_NAME}.app" "$DIST/${APP_NAME}.app"

rm -rf "$WORK"

echo ""
echo "Done (notarized + stapled):"
ls -lh "$DIST/$DMG_NAME" "$DIST/${APP_NAME}.app"
echo ""
echo "Path: $DIST/$DMG_NAME"
echo "Gatekeeper: Developer ID + notarized. Double-click should open without the scary dialog."
