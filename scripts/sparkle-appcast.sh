#!/usr/bin/env bash
# Generate Sparkle appcast.xml for the latest notarized DMG and copy it into
# the local (gitignored) Cloudflare Worker public assets.
#
# Usage:
#   ./scripts/sparkle-appcast.sh                 # uses dist/TinyFire-<version>.dmg
#   ./scripts/sparkle-appcast.sh path/to.dmg
#
# Requires:
#   - secrets/sparkle_eddsa_private.key (gitignored), or Keychain ed25519 key
#   - Network once to download Sparkle tools into scripts/.sparkle-tools/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
TOOLS="$ROOT/scripts/.sparkle-tools"
STAGING="$DIST/sparkle"
PRIVATE_KEY="$ROOT/secrets/sparkle_eddsa_private.key"
BACKEND_PUBLIC="$ROOT/backend/public"
FEED_NAME="appcast.xml"

MARKETING_VERSION="$(
  cd "$ROOT" && xcodebuild -scheme tinyFire -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION / {print $2; exit}' | tr -d '[:space:]'
)"
VERSION="${MARKETING_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  echo "ERROR: could not read MARKETING_VERSION" >&2
  exit 1
fi

DMG="${1:-$DIST/TinyFire-${VERSION}.dmg}"
if [[ ! -f "$DMG" ]]; then
  echo "ERROR: DMG not found: $DMG" >&2
  echo "Run ./scripts/make-dmg.sh first." >&2
  exit 1
fi

ensure_tools() {
  if [[ -x "$TOOLS/bin/generate_appcast" ]]; then
    return
  fi
  echo "==> Fetching Sparkle tools..."
  mkdir -p "$TOOLS"
  local tmp
  tmp="$(mktemp -d)"
  local url
  url="$(curl -sL https://api.github.com/repos/sparkle-project/Sparkle/releases/latest | python3 -c "
import sys,json
rel=json.load(sys.stdin)
for a in rel.get('assets',[]):
  n=a['name']
  if n.endswith('.tar.xz') and n.startswith('Sparkle-') and 'for-Swift' not in n:
    print(a['browser_download_url']); break
")"
  curl -sL "$url" -o "$tmp/sparkle.tar.xz"
  tar -xf "$tmp/sparkle.tar.xz" -C "$tmp"
  rm -rf "$TOOLS"
  mkdir -p "$TOOLS"
  # Archive extracts bin/ next to Sparkle.framework
  local root_dir
  root_dir="$(find "$tmp" -type d -name bin -print -quit | sed 's|/bin$||')"
  cp -R "$root_dir/bin" "$TOOLS/bin"
  xattr -dr com.apple.quarantine "$TOOLS/bin" 2>/dev/null || true
  rm -rf "$tmp"
}

ensure_tools

mkdir -p "$STAGING"
# Keep prior appcast so history accumulates.
if [[ -f "$BACKEND_PUBLIC/$FEED_NAME" && ! -f "$STAGING/$FEED_NAME" ]]; then
  cp "$BACKEND_PUBLIC/$FEED_NAME" "$STAGING/$FEED_NAME"
fi

cp "$DMG" "$STAGING/$(basename "$DMG")"

# Optional release notes beside the archive (same basename).
NOTES_MD="$STAGING/TinyFire-${VERSION}.md"
if [[ ! -f "$NOTES_MD" ]]; then
  cat > "$NOTES_MD" <<EOF
## TinyFire ${VERSION}

In-app update via Sparkle.
EOF
fi

DOWNLOAD_PREFIX="https://github.com/wdkwdkwdk/tinyfire/releases/download/v${VERSION}/"
KEY_ARGS=()
if [[ -f "$PRIVATE_KEY" ]]; then
  KEY_ARGS+=(--ed-key-file "$PRIVATE_KEY")
fi

echo "==> Generating appcast for v${VERSION}..."
"$TOOLS/bin/generate_appcast" \
  "${KEY_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --link "https://tinyfire.createfun.ai/" \
  -o "$STAGING/$FEED_NAME" \
  "$STAGING"

test -f "$STAGING/$FEED_NAME"

# generate_appcast applies --download-url-prefix to every enclosure; rewrite
# TinyFire-x.y.z.dmg URLs so each version points at its own GitHub release.
python3 - <<'PY' "$STAGING/$FEED_NAME"
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
def fix(m):
    ver = m.group(1)
    return f"https://github.com/wdkwdkwdk/tinyfire/releases/download/v{ver}/TinyFire-{ver}.dmg"
text = re.sub(
    r"https://github.com/wdkwdkwdk/tinyfire/releases/download/v[^/\"]+/TinyFire-(\d+\.\d+\.\d+)\.dmg",
    fix,
    text,
)
path.write_text(text)
PY

if [[ -d "$BACKEND_PUBLIC" ]]; then
  cp "$STAGING/$FEED_NAME" "$BACKEND_PUBLIC/$FEED_NAME"
  echo "==> Copied appcast → backend/public/$FEED_NAME"
else
  echo "WARN: backend/public missing — appcast left at $STAGING/$FEED_NAME" >&2
fi

echo ""
echo "Done:"
echo "  $STAGING/$FEED_NAME"
echo "  Enclosure prefix (new items / deltas): $DOWNLOAD_PREFIX"
if compgen -G "$STAGING/*.delta" > /dev/null; then
  echo "  Delta updates (upload with the GitHub release):"
  ls -1 "$STAGING"/*.delta | sed 's|^|    |'
fi
echo "Deploy with: cd backend && npx wrangler deploy"
echo "Verify: curl -sS https://tinyfire.createfun.ai/appcast.xml | head"
