#!/usr/bin/env bash
# build-app.sh — Build, assemble, sign, and notarise Clipster.app
#
# Usage: ./scripts/build-app.sh [clean|build|assemble|sign|notarise|all]
#
# Environment variables:
#   VERSION        App version string (default: 0.1.0)
#   BUILD_NUMBER   CFBundleVersion integer (default: 1)
#   DEVELOPER_ID   Codesign identity, e.g. "Developer ID Application: Romeo Folie (TEAMID)"
#   APPLE_ID       Apple ID email (for notarytool)
#   TEAM_ID        Apple Developer Team ID (for notarytool)
#   APP_PASSWORD   App-specific password from appleid.apple.com (for notarytool)
#
# Typical workflow:
#   ./scripts/build-app.sh all          # build universal binary + assemble bundle
#   ./scripts/build-app.sh sign         # sign with DEVELOPER_ID
#   ./scripts/build-app.sh notarise     # notarise + staple (requires sign first)

set -euo pipefail

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

APP_NAME="Clipster"
BINARY_NAME="ClipsterApp"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

INFO_PLIST_SRC="$REPO_ROOT/ClipsterApp/Sources/ClipsterApp/Info.plist"
ENTITLEMENTS="$REPO_ROOT/ClipsterApp/Sources/ClipsterApp/ClipsterApp.entitlements"
UNIVERSAL_BINARY="$DIST_DIR/$BINARY_NAME-universal"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo "  → $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

# ─── Steps ───────────────────────────────────────────────────────────────────

cmd_clean() {
    log "Cleaning dist/..."
    rm -rf "$APP_BUNDLE" "$UNIVERSAL_BINARY" "$DIST_DIR/$APP_NAME.zip"
    ok "Clean complete"
}

cmd_build() {
    log "Building arm64 release..."
    (cd "$REPO_ROOT/ClipsterApp" && swift build -c release --arch arm64)

    log "Building x86_64 release..."
    (cd "$REPO_ROOT/ClipsterApp" && swift build -c release --arch x86_64)

    log "Creating universal binary..."
    mkdir -p "$DIST_DIR"
    lipo -create \
        "$REPO_ROOT/ClipsterApp/.build/arm64-apple-macosx/release/$BINARY_NAME" \
        "$REPO_ROOT/ClipsterApp/.build/x86_64-apple-macosx/release/$BINARY_NAME" \
        -output "$UNIVERSAL_BINARY"

    ok "Universal binary: $UNIVERSAL_BINARY"
    file "$UNIVERSAL_BINARY"
}

cmd_assemble() {
    [[ -f "$UNIVERSAL_BINARY" ]] || fail "Universal binary not found — run 'build' first"
    [[ -f "$INFO_PLIST_SRC" ]] || fail "Info.plist not found at $INFO_PLIST_SRC"

    log "Assembling $APP_NAME.app bundle..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

    # Binary
    cp "$UNIVERSAL_BINARY" "$MACOS_DIR/$BINARY_NAME"
    chmod +x "$MACOS_DIR/$BINARY_NAME"

    # Info.plist — inject VERSION and BUILD_NUMBER
    # Replaces the placeholder values in the source Info.plist.
    # CFBundleShortVersionString: replace "0.1.0" with $VERSION
    # CFBundleVersion: replace the first standalone "<string>1</string>" with BUILD_NUMBER
    python3 - "$INFO_PLIST_SRC" "$CONTENTS/Info.plist" "$VERSION" "$BUILD_NUMBER" <<'PYEOF'
import sys, re

src, dst, version, build = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()

# Replace CFBundleShortVersionString value
text = re.sub(
    r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>' + version + r'\g<2>',
    text
)
# Replace CFBundleVersion value
text = re.sub(
    r'(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>' + build + r'\g<2>',
    text
)

open(dst, 'w').write(text)
print("  Injected version:", version, "build:", build)
PYEOF

    ok "Bundle assembled: $APP_BUNDLE"
}

cmd_sign() {
    local DEVELOPER_ID="${DEVELOPER_ID:?Set DEVELOPER_ID — e.g. export DEVELOPER_ID='Developer ID Application: Romeo Folie (TEAMID)'}"

    [[ -d "$APP_BUNDLE" ]] || fail "$APP_BUNDLE not found — run 'assemble' first"
    [[ -f "$ENTITLEMENTS" ]] || fail "Entitlements not found at $ENTITLEMENTS"

    log "Signing $APP_NAME.app with hardened runtime..."
    codesign \
        --force \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID" \
        --timestamp \
        "$APP_BUNDLE"

    log "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | grep -v "^$" || true
    spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || true

    ok "Signed: $APP_BUNDLE"
}

cmd_notarise() {
    local APPLE_ID="${APPLE_ID:?Set APPLE_ID (your Apple ID email)}"
    local TEAM_ID="${TEAM_ID:?Set TEAM_ID (Apple Developer Team ID)}"
    local APP_PASSWORD="${APP_PASSWORD:?Set APP_PASSWORD (app-specific password from appleid.apple.com)}"

    [[ -d "$APP_BUNDLE" ]] || fail "$APP_BUNDLE not found — run 'assemble' and 'sign' first"

    local ZIP="$DIST_DIR/$APP_NAME-notarisation.zip"

    log "Zipping bundle for submission..."
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

    log "Submitting to Apple notarytool (this may take a few minutes)..."
    xcrun notarytool submit "$ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    log "Stapling notarisation ticket..."
    xcrun stapler staple "$APP_BUNDLE"

    rm -f "$ZIP"
    ok "Notarised and stapled: $APP_BUNDLE"

    log "Final Gatekeeper check..."
    spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || true
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

CMD="${1:-all}"

case "$CMD" in
    clean)    cmd_clean ;;
    build)    cmd_build ;;
    assemble) cmd_assemble ;;
    sign)     cmd_sign ;;
    notarise) cmd_notarise ;;
    all)
        cmd_clean
        cmd_build
        cmd_assemble
        ok "Build complete. Run 'sign' next (requires DEVELOPER_ID)."
        ;;
    *)
        echo "Usage: $0 [clean|build|assemble|sign|notarise|all]"
        echo ""
        echo "  all        Clean + build universal binary + assemble bundle (default)"
        echo "  clean      Remove dist/ artifacts"
        echo "  build      Compile arm64 + x86_64 + lipo universal binary"
        echo "  assemble   Assemble .app bundle from universal binary + Info.plist"
        echo "  sign       Codesign bundle with hardened runtime (needs DEVELOPER_ID)"
        echo "  notarise   Submit to Apple notarytool + staple (needs APPLE_ID,TEAM_ID,APP_PASSWORD)"
        exit 1
        ;;
esac
