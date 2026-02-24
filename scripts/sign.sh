#!/usr/bin/env bash
# sign.sh — Code signing and notarisation pipeline for clipsterd.
#
# Usage:
#   ./scripts/sign.sh sign     — sign binary only (local testing)
#   ./scripts/sign.sh notarise — sign + submit to Apple for notarisation + verify
#   ./scripts/sign.sh verify   — verify an already-signed binary
#
# Required environment variables (set in shell, not hardcoded here):
#   DEVELOPER_ID      — e.g. "Developer ID Application: Romeo Folie (TEAMID12AB)"
#   APPLE_ID          — Apple ID email used for App Store Connect / notarytool
#   TEAM_ID           — 10-character Apple Developer Team ID
#   APP_PASSWORD      — App-specific password from appleid.apple.com
#                       Store this in Keychain and retrieve with:
#                       security find-generic-password -s "clipster-notarise" -w
#
# Binary location expected at:
#   ./clipsterd/.build/release/clipsterd
#
# PRD §9 — notarisation required for Gatekeeper (Phase 0 gate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$PROJECT_DIR/clipsterd/.build/release/clipsterd"
ENTITLEMENTS="$PROJECT_DIR/support/entitlements.plist"
ZIP_PATH="$PROJECT_DIR/dist/clipsterd.zip"

# ─── Validation ───────────────────────────────────────────────────────────────

validate_env() {
    local missing=0
    for var in DEVELOPER_ID APPLE_ID TEAM_ID APP_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: \$$var is not set" >&2
            missing=1
        fi
    done
    [[ $missing -eq 0 ]] || exit 1
}

check_binary() {
    if [[ ! -f "$BINARY" ]]; then
        echo "ERROR: Binary not found at $BINARY" >&2
        echo "Run 'make build' first." >&2
        exit 1
    fi
    echo "Binary: $BINARY"
    file "$BINARY"
}

# ─── Sign ─────────────────────────────────────────────────────────────────────

do_sign() {
    echo "→ Signing with Developer ID..."
    codesign \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        --force \
        --verbose \
        "$BINARY"

    echo "→ Verifying signature..."
    codesign --verify --strict --verbose=2 "$BINARY"
    spctl --assess --type exec --verbose "$BINARY" 2>&1 || true
    echo "✓ Signed successfully"
}

# ─── Notarise ─────────────────────────────────────────────────────────────────

do_notarise() {
    mkdir -p "$(dirname "$ZIP_PATH")"

    echo "→ Creating zip for notarisation..."
    ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"
    echo "  Archive: $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))"

    echo "→ Submitting to Apple notarisation service..."
    # --wait blocks until Apple responds (typically 30–120s)
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait \
        --verbose

    echo "→ Checking notarisation log..."
    # notarytool submit --wait already prints the result.
    # For detailed log (if submission ID is known), run:
    #   xcrun notarytool log <submission-id> --apple-id ... --team-id ... --password ...

    echo ""
    echo "✓ Notarisation complete"
    echo ""
    echo "NOTE: CLI binaries cannot be stapled (stapling is for .app bundles)."
    echo "Gatekeeper will validate the notarisation ticket online when the binary"
    echo "is first run on a quarantined machine."
    echo "To verify Gatekeeper acceptance on a clean macOS install, run:"
    echo "  spctl --assess --type exec --verbose $BINARY"
}

# ─── Verify ───────────────────────────────────────────────────────────────────

do_verify() {
    echo "→ Verifying signature and notarisation..."
    codesign --verify --strict --verbose=2 "$BINARY"
    spctl --assess --type exec --verbose "$BINARY"
    echo "✓ Binary accepted by Gatekeeper"
}

# ─── SHA-256 checksum ─────────────────────────────────────────────────────────

do_checksum() {
    local arch
    arch=$(uname -m)
    local sum_file="$PROJECT_DIR/dist/clipsterd-darwin-${arch}.sha256"
    shasum -a 256 "$BINARY" > "$sum_file"
    echo "Checksum written: $sum_file"
    cat "$sum_file"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

CMD="${1:-help}"

case "$CMD" in
    sign)
        validate_env
        check_binary
        do_sign
        ;;
    notarise)
        validate_env
        check_binary
        do_sign
        do_notarise
        do_checksum
        ;;
    verify)
        check_binary
        do_verify
        ;;
    checksum)
        check_binary
        do_checksum
        ;;
    help|*)
        echo "Usage: $0 {sign|notarise|verify|checksum}"
        echo ""
        echo "Required env vars (for sign/notarise):"
        echo "  DEVELOPER_ID    — Developer ID Application string"
        echo "  APPLE_ID        — Apple ID email"
        echo "  TEAM_ID         — 10-char team ID"
        echo "  APP_PASSWORD    — App-specific password"
        echo ""
        echo "Recommended: store APP_PASSWORD in Keychain:"
        echo "  security add-generic-password -s clipster-notarise -a \$APPLE_ID -w"
        echo "  export APP_PASSWORD=\$(security find-generic-password -s clipster-notarise -w)"
        ;;
esac
