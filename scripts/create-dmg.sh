#!/usr/bin/env bash
# create-dmg.sh — Package Clipster.app into a distributable DMG
#
# Prerequisites:
#   - dist/Clipster.app must exist (run scripts/build-app.sh first)
#   - For a release DMG, the .app should be signed and notarised before packaging
#
# Usage:
#   VERSION=0.1.0 ./scripts/create-dmg.sh
#   make dmg
#
# Output:
#   dist/Clipster-<VERSION>.dmg  (compressed UDZO)
#
# After upload to GitHub Releases:
#   1. Run: shasum -a 256 dist/Clipster-<VERSION>.dmg
#   2. Update Casks/clipster.rb sha256 field with the printed hash
#   3. Update docs/appcast.xml with the file length + Ed25519 signature

set -euo pipefail

VERSION="${VERSION:-0.1.0}"

APP_NAME="Clipster"
BINARY_NAME="${APP_NAME}.app"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$BINARY_NAME"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

# ─── Preflight ────────────────────────────────────────────────────────────────

log()  { echo "  → $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

[[ -d "$APP_BUNDLE" ]] || fail "$BINARY_NAME not found in dist/. Run 'make build-app' first."

# ─── Staging area ─────────────────────────────────────────────────────────────

log "Staging DMG contents..."
cp -r "$APP_BUNDLE" "$STAGING_DIR/$BINARY_NAME"

# /Applications symlink lets the user drag-install from Finder
ln -s /Applications "$STAGING_DIR/Applications"

# Optional background image — skip if not present
BACKGROUND="$REPO_ROOT/assets/dmg-background.png"
if [[ -f "$BACKGROUND" ]]; then
    mkdir -p "$STAGING_DIR/.background"
    cp "$BACKGROUND" "$STAGING_DIR/.background/background.png"
    log "Background image included"
fi

ok "Staging complete: $STAGING_DIR"

# ─── Create DMG ───────────────────────────────────────────────────────────────

# Remove any previous DMG at the same path
rm -f "$DMG_PATH"

log "Creating compressed DMG (this may take a moment)..."

# Calculate a volume size with 20MB headroom
APP_SIZE_MB=$(du -sm "$STAGING_DIR" | awk '{print $1}')
VOLUME_SIZE_MB=$((APP_SIZE_MB + 20))

# Step 1: Create a read-write DMG from the staging directory
TEMP_DMG="$DIST_DIR/.tmp_${APP_NAME}.dmg"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    -size "${VOLUME_SIZE_MB}m" \
    "$TEMP_DMG" >/dev/null

# Step 2: Convert to compressed, internet-enabled DMG
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" >/dev/null

rm -f "$TEMP_DMG"

# ─── Summary ─────────────────────────────────────────────────────────────────

DMG_SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

ok "DMG created: $DMG_PATH ($DMG_SIZE)"
echo ""
echo "  SHA-256: $DMG_SHA256"
echo ""
echo "  Next steps:"
echo "    1. Upload $DMG_NAME to the GitHub Release for v${VERSION}"
echo "    2. Copy the SHA-256 above into Casks/clipster.rb (sha256 field)"
echo "    3. Sign the DMG with Sparkle: ./dist/Sparkle/bin/sign_update $DMG_PATH"
echo "    4. Update docs/appcast.xml with length + edSignature from step 3"
