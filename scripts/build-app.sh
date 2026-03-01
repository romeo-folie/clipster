#!/usr/bin/env bash
# build-app.sh — Build, assemble, sign, and notarise Clipster.app
#
# Usage: ./scripts/build-app.sh [clean|build|assemble|sign|notarise|all]
#
# Environment variables:
#   VERSION          App version string (default: 0.1.0)
#   BUILD_NUMBER     CFBundleVersion integer (default: 1)
#   DEVELOPER_ID     Codesign identity, e.g. "Developer ID Application: Romeo Folie (TEAMID)"
#
#   Notarisation — choose ONE of:
#   KEYCHAIN_PROFILE  Keychain profile name created via:
#                       xcrun notarytool store-credentials <profile-name> \
#                         --apple-id <email> --team-id <TEAMID> --password <app-password>
#                     Preferred: credentials stay out of shell history and ps output.
#   APPLE_ID + TEAM_ID + APP_PASSWORD
#                     Fallback if keychain profile is not set up.
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
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$CONTENTS/Frameworks"

    # Binary
    cp "$UNIVERSAL_BINARY" "$MACOS_DIR/$BINARY_NAME"
    chmod +x "$MACOS_DIR/$BINARY_NAME"

    # Embed Sparkle.framework — Sparkle is a dynamic framework (@rpath-linked).
    # SPM places a per-arch Sparkle.framework slice next to the binary in .build/.
    # We build a universal Sparkle.framework by lipo-ing arm64 + x86_64 slices,
    # then embed it at Contents/Frameworks/ per standard .app bundle convention.
    # The loader rpath is updated from @loader_path (dev build dir) to
    # @executable_path/../Frameworks (runtime .app bundle path).
    SPARKLE_ARM64="$REPO_ROOT/ClipsterApp/.build/arm64-apple-macosx/release/Sparkle.framework"
    SPARKLE_X86="$REPO_ROOT/ClipsterApp/.build/x86_64-apple-macosx/release/Sparkle.framework"
    SPARKLE_DST="$CONTENTS/Frameworks/Sparkle.framework"

    if [[ -d "$SPARKLE_ARM64" ]]; then
        log "Embedding Sparkle.framework (universal)..."
        # Use arm64 framework as the base (preserves headers, Resources, etc.)
        cp -r "$SPARKLE_ARM64" "$SPARKLE_DST"

        if [[ -d "$SPARKLE_X86" ]]; then
            # Lipo the framework binary itself into a universal slice.
            # SPARKLE_ARM64 / SPARKLE_X86 already point to Sparkle.framework —
            # the binary lives at Versions/B/Sparkle inside that directory.
            SPARKLE_BIN="Versions/B/Sparkle"
            lipo -create \
                "$SPARKLE_ARM64/$SPARKLE_BIN" \
                "$SPARKLE_X86/$SPARKLE_BIN" \
                -output "$SPARKLE_DST/Versions/B/Sparkle"
            # Keep the top-level symlink in sync
            cp "$SPARKLE_DST/Versions/B/Sparkle" "$SPARKLE_DST/Sparkle" 2>/dev/null || true
        fi

        # Fix rpath in the app binary: @loader_path resolves to MacOS/ (correct at
        # dev time, wrong in .app). Replace with @executable_path/../Frameworks.
        install_name_tool \
            -delete_rpath "@loader_path" \
            -add_rpath "@executable_path/../Frameworks" \
            "$MACOS_DIR/$BINARY_NAME" 2>/dev/null || \
        install_name_tool \
            -add_rpath "@executable_path/../Frameworks" \
            "$MACOS_DIR/$BINARY_NAME"

        ok "Sparkle.framework embedded and rpath updated"
    else
        fail "Sparkle.framework not found at $SPARKLE_ARM64 — run 'build' first. Assemble aborted."
    fi

    # Info.plist — inject VERSION and BUILD_NUMBER
    # Replaces the placeholder values in the source Info.plist.
    # CFBundleShortVersionString: replace "0.1.0" with $VERSION
    # CFBundleVersion: replace standalone value after CFBundleVersion key with BUILD_NUMBER
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

    # PkgInfo — identifies the app type to older tools (Finder, etc.)
    echo -n "APPL????" > "$CONTENTS/PkgInfo"

    ok "Bundle assembled: $APP_BUNDLE"
}

cmd_sign() {
    local DEVELOPER_ID="${DEVELOPER_ID:?Set DEVELOPER_ID — e.g. export DEVELOPER_ID='Developer ID Application: Romeo Folie (TEAMID)'}"

    [[ -d "$APP_BUNDLE" ]] || fail "$APP_BUNDLE not found — run 'assemble' first"
    [[ -f "$ENTITLEMENTS" ]] || fail "Entitlements not found at $ENTITLEMENTS"

    # macOS requires inside-out signing: every nested bundle must be signed with
    # its own valid signature before the enclosing bundle is sealed. Signing the
    # outer bundle first immediately invalidates inner signatures, causing
    # Gatekeeper deep validation to reject the app.
    #
    # Sparkle.framework contains three levels of nesting:
    #   Versions/B/XPCServices/Downloader.xpc   ← sign first
    #   Versions/B/XPCServices/Installer.xpc    ← sign first
    #   Versions/B/Updater.app                  ← sign second
    #   Versions/B/Autoupdate                   ← sign (standalone executable)
    #   Sparkle.framework itself                ← sign third
    #   ClipsterApp.app (outer bundle)          ← sign last

    local SPARKLE_FW="$CONTENTS/Frameworks/Sparkle.framework"

    if [[ -d "$SPARKLE_FW" ]]; then
        local SPARKLE_VB="$SPARKLE_FW/Versions/B"

        # 1. XPC services (innermost)
        for xpc in "$SPARKLE_VB/XPCServices/"*.xpc; do
            [[ -d "$xpc" ]] || continue
            log "Signing $(basename "$xpc")..."
            codesign --force --options runtime \
                --sign "$DEVELOPER_ID" --timestamp "$xpc"
        done

        # 2. Updater.app (nested app bundle inside framework)
        if [[ -d "$SPARKLE_VB/Updater.app" ]]; then
            log "Signing Updater.app..."
            codesign --force --options runtime \
                --sign "$DEVELOPER_ID" --timestamp "$SPARKLE_VB/Updater.app"
        fi

        # 3. Autoupdate standalone executable
        if [[ -f "$SPARKLE_VB/Autoupdate" ]]; then
            log "Signing Autoupdate..."
            codesign --force --options runtime \
                --sign "$DEVELOPER_ID" --timestamp "$SPARKLE_VB/Autoupdate"
        fi

        # 4. Outer Sparkle.framework (seals everything signed above)
        log "Signing Sparkle.framework..."
        codesign --force --options runtime \
            --sign "$DEVELOPER_ID" --timestamp "$SPARKLE_FW"
    fi

    # 5. Outer app bundle (seals everything, including Contents/Frameworks/)
    log "Signing $APP_NAME.app with hardened runtime..."
    codesign \
        --force \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID" \
        --timestamp \
        "$APP_BUNDLE"

    log "Verifying signature (deep)..."
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | grep -v "^$" || true
    # spctl returns non-zero before notarisation — expected at this stage.
    spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || true

    ok "Signed: $APP_BUNDLE"
}

cmd_notarise() {
    [[ -d "$APP_BUNDLE" ]] || fail "$APP_BUNDLE not found — run 'assemble' and 'sign' first"

    local ZIP="$DIST_DIR/$APP_NAME-notarisation.zip"

    log "Zipping bundle for submission..."
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"

    log "Submitting to Apple notarytool (this may take a few minutes)..."

    # Prefer --keychain-profile: credentials are stored in macOS Keychain and
    # never appear in ps output or shell history.
    # Setup (one-time):
    #   xcrun notarytool store-credentials <profile-name> \
    #     --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
    # Then: export KEYCHAIN_PROFILE=<profile-name>
    #
    # Fallback to --apple-id / --password when KEYCHAIN_PROFILE is not set.
    if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait
    else
        local APPLE_ID="${APPLE_ID:?Set KEYCHAIN_PROFILE (preferred) or APPLE_ID + TEAM_ID + APP_PASSWORD}"
        local TEAM_ID="${TEAM_ID:?Set TEAM_ID}"
        local APP_PASSWORD="${APP_PASSWORD:?Set APP_PASSWORD (app-specific password — use KEYCHAIN_PROFILE instead to avoid credential exposure in ps output)}"
        xcrun notarytool submit "$ZIP" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$APP_PASSWORD" \
            --wait
    fi

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
        echo "  notarise   Submit to Apple notarytool + staple (set KEYCHAIN_PROFILE, or APPLE_ID+TEAM_ID+APP_PASSWORD)"
        exit 1
        ;;
esac
