#!/usr/bin/env bash
# verify-phase5-gate.sh — Phase 5.0 CGEvent paste gate verification.
#
# Run this on Romeo's Mac after:
#   ./scripts/sign-prototype.sh notarise
#
# Usage:
#   ./scripts/verify-phase5-gate.sh

set -euo pipefail

BINARY="$(cd "$(dirname "$0")/.." && pwd)/cgevent-prototype/.build/release/cgevent-prototype"
PASS=0
FAIL=0
WARN=0

pass() { echo "  ✓ PASS — $1"; ((PASS++)) || true; }
fail() { echo "  ✗ FAIL — $1"; ((FAIL++)) || true; }
warn() { echo "  ⚠ WARN — $1"; ((WARN++)) || true; }
header() { echo ""; echo "── $1 ──"; }

header "1. Binary"
if [[ -f "$BINARY" && -x "$BINARY" ]]; then
    pass "Binary exists and is executable"
    file "$BINARY" | sed 's/^/    /'
else
    fail "Binary not found: $BINARY — run: ./scripts/sign-prototype.sh build"
fi

header "2. Signature"
if codesign --verify --strict "$BINARY" 2>/dev/null; then
    pass "Binary is signed"
    codesign -d --verbose "$BINARY" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp" | sed 's/^/    /'
else
    fail "Binary is not signed — run: ./scripts/sign-prototype.sh sign"
fi

header "3. Gatekeeper"
if spctl --assess --type exec "$BINARY" 2>/dev/null; then
    pass "Gatekeeper accepts binary (notarisation confirmed)"
else
    warn "Gatekeeper rejected binary — has it been notarised? Run: ./scripts/sign-prototype.sh notarise"
fi

header "4. Accessibility permission"
echo "  This check requires manual verification."
echo "  The binary will prompt for Accessibility access on first run."
echo "  Confirm in: System Settings → Privacy & Security → Accessibility"

header "5. CGEvent paste (manual gate)"
echo ""
echo "  Run the prototype:"
echo "    $BINARY"
echo ""
echo "  When prompted:"
echo "    1. Grant Accessibility permission if requested, then re-run"
echo "    2. Open a target app: TextEdit, Terminal, or Notes"
echo "    3. Place cursor in a text field"
echo "    4. Switch back to the terminal running the prototype — it pastes in 4 seconds"
echo "    5. Observe whether the test string appears in the target app"
echo ""
echo "  PASS → test string pasted into target app"
echo "  FAIL → no paste, or blocked by macOS after notarisation"

header "Summary"
echo "  Automated checks: PASS=$PASS WARN=$WARN FAIL=$FAIL"
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo "  ✗ Gate: NOT PASSED — $FAIL automated failure(s). Resolve before proceeding."
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo "  ⚠ Gate: PARTIAL — complete manual CGEvent check above."
    echo "    If paste succeeds: Phase 5.0 PASS → proceed to Phase 5.1"
    echo "    If paste fails: evaluate v3 PRD §7.3 fallback strategies. Escalate to Alfred."
else
    echo "  ✓ Automated checks passed."
    echo "    Complete the manual CGEvent paste check above to close the gate."
    echo "    Report result on GitHub issue #25."
fi
