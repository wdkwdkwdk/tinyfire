#!/usr/bin/env bash
# Build a distributable TinyFire.dmg (Release, arm64).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build outside iCloud Drive — resource forks break codesign there.
WORK="${TMPDIR:-/tmp}/TinyFire-dmg-build"
DIST="$ROOT/dist"
STAGE="$WORK/dmg-stage"
DERIVED="$WORK/DerivedData"
APP_NAME="TinyFire"
PRODUCT_APP="tinyFire.app"

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"

echo "==> Reading version..."
MARKETING_VERSION="$(cd "$ROOT" && xcodebuild -scheme tinyFire -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/MARKETING_VERSION / {print $2; exit}' | tr -d '[:space:]')"
VERSION="${MARKETING_VERSION:-1.0}"
DMG_NAME="TinyFire-${VERSION}.dmg"
VOL_NAME="TinyFire"

echo "==> Building Release (work dir: ${WORK})..."
cd "$ROOT"
xcodebuild \
  -scheme tinyFire \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

SRC_APP="$DERIVED/Build/Products/Release/$PRODUCT_APP"
test -d "$SRC_APP"

# Embed private update endpoint when present (gitignored locally).
ENDPOINT_PLIST="$ROOT/tinyFire/UpdateEndpoint.plist"
if [[ -f "$ENDPOINT_PLIST" ]]; then
  mkdir -p "$SRC_APP/Contents/Resources"
  cp "$ENDPOINT_PLIST" "$SRC_APP/Contents/Resources/UpdateEndpoint.plist"
fi

# Sanity: refuse to ship if marketing version didn't land in the binary.
BUILT_VER="$(defaults read "$SRC_APP/Contents/Info" CFBundleShortVersionString)"
echo "==> Built app version: ${BUILT_VER}"
if [[ "$BUILT_VER" != "$VERSION" ]]; then
  echo "ERROR: expected marketing version ${VERSION}, got ${BUILT_VER}" >&2
  exit 1
fi

echo "==> Staging DMG contents..."
mkdir -p "$STAGE"
# Copy out of iCloud-derived path into /tmp stage
ditto "$SRC_APP" "$STAGE/${APP_NAME}.app"
xattr -cr "$STAGE/${APP_NAME}.app"
ln -sf /Applications "$STAGE/Applications"

# Ad-hoc sign for local distribution
codesign --force --deep --options runtime --sign - "$STAGE/${APP_NAME}.app"

echo "==> Creating ${DMG_NAME}..."
rm -f "$DIST/$DMG_NAME"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DIST/$DMG_NAME"

# Keep a copy of the .app next to the dmg for convenience
rm -rf "$DIST/${APP_NAME}.app"
ditto "$STAGE/${APP_NAME}.app" "$DIST/${APP_NAME}.app"

# Attach volume icon if available
ICNS="$ROOT/branding/TinyFire.icns"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$STAGE/.VolumeIcon.icns" 2>/dev/null || true
fi

rm -rf "$WORK"

echo ""
echo "Done:"
ls -lh "$DIST/$DMG_NAME" "$DIST/${APP_NAME}.app"
echo ""
echo "Path: $DIST/$DMG_NAME"
echo "Note: not notarized. Colleagues: right-click TinyFire.app -> Open (first launch)."
