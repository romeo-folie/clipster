#!/usr/bin/env bash
# sign-prototype.sh — Build, sign, and notarise the CGEvent paste prototype.
#
# Usage:
#   ./scripts/sign-prototype.sh build      — build only
#   ./scripts/sign-prototype.sh sign       — build + sign
#   ./scripts/sign-prototype.sh notarise   — build + sign + submit for notarisation
#   ./scripts/sign-prototype.sh verify     — verify signature + Gatekeeper
#
# Required env vars (for sign/notarise):
#   DEVELOPER_ID    — e.g. "Developer ID Application: Romeo Folie (TEAMID12AB)"
#   APPLE_ID        — Apple ID email
#   TEAM_ID         — 10-char team ID
#   APP_PASSWORD    — App-specific password (from appleid.apple.com)
#                     Recommended: security find-generic-password -s clipster-notarise -w
#
# Phase 5 gate: PRD v3 §7.3 / §13

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROTOTYPE_DIR="$PROJECT_DIR/cgevent-prototype"
BINARY="$PROTOTYPE_DIR/.build/release/cgevent-prototype"
ENTITLEMENTS="$PROTOTYPE_DIR/support/entitlements.plist"
ZIP_PATH="$PROJECT_DIR/dist/cgevent-prototype.zip"

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

do_build() {
    echo "→ Building cgevent-prototype (release)…"
    cd "$PROTOTYPE_DIR" && swift build -c release
    echo "✓ Built: $BINARY"
    file "$BINARY"
}

do_sign() {
    echo "→ Signing with Developer ID (hardened runtime)…"
    codesign \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        --force \
        --verbose \
        "$BINARY"
    echo "→ Verifying signature…"
    codesign --verify --strict --verbose=2 "$BINARY"
    echo "✓ Signed"
}

do_notarise() {
    mkdir -p "$(dirname "$ZIP_PATH")"
    echo "→ Creating zip for notarisation…"
    ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"

    echo "→ Submitting to Apple notarisation service (--wait)…"
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait \
        --verbose

    echo ""
    echo "✓ Notarisation complete"
    echo "  NOTE: CLI binaries cannot be stapled. Gatekeeper validates the"
    echo "  ticket online when the binary first runs from a quarantined path."
    echo ""
    echo "  To set quarantine flag and test Gatekeeper acceptance:"
    echo "    xattr -w com.apple.quarantine \"0083;00000000;Safari;\" $BINARY"
    echo "    $BINARY"
}

do_verify() {
    echo "→ Verifying signature…"
    codesign --verify --strict --verbose=2 "$BINARY"
    echo "→ Checking Gatekeeper acceptance…"
    spctl --assess --type exec --verbose "$BINARY"
    echo "✓ Gatekeeper accepts binary"
}

CMD="${1:-help}"

case "$CMD" in
    build)
        do_build
        ;;
    sign)
        validate_env
        do_build
        do_sign
        ;;
    notarise)
        validate_env
        do_build
        do_sign
        do_notarise
        ;;
    verify)
        do_verify
        ;;
    help|*)
        echo "Usage: $0 {build|sign|notarise|verify}"
        echo ""
        echo "Required env vars (sign/notarise): DEVELOPER_ID, APPLE_ID, TEAM_ID, APP_PASSWORD"
        ;;
esac
