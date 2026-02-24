#!/usr/bin/env bash
# verify-phase0.sh — Phase 0 gate verification procedure.
#
# Run this on Romeo's Mac after `make build && make install`.
# Each check prints PASS / FAIL / WARN.
# All checks must PASS before Phase 0 is declared complete.
#
# Usage:
#   ./scripts/verify-phase0.sh
#
# Pre-conditions:
#   - `make build` has been run (binary at /usr/local/bin/clipsterd)
#   - LaunchAgent has been loaded: `make install-launchagent`

set -euo pipefail

PASS=0
FAIL=0
WARN=0

PLIST="$HOME/Library/LaunchAgents/com.clipster.daemon.plist"
BINARY="/usr/local/bin/clipsterd"
DB="$HOME/Library/Application Support/Clipster/history.db"
LOG="/tmp/clipsterd.log"

pass()  { echo "  ✓ PASS — $1"; ((PASS++)) || true; }
fail()  { echo "  ✗ FAIL — $1"; ((FAIL++)) || true; }
warn()  { echo "  ⚠ WARN — $1"; ((WARN++)) || true; }
header(){ echo ""; echo "── $1 ──"; }

# ─── 1. Binary ────────────────────────────────────────────────────────────────

header "1. Binary"

if [[ -f "$BINARY" && -x "$BINARY" ]]; then
    pass "Binary exists and is executable: $BINARY"
else
    fail "Binary missing or not executable: $BINARY — run 'make build && make install'"
fi

# ─── 2. LaunchAgent plist ─────────────────────────────────────────────────────

header "2. LaunchAgent"

if [[ -f "$PLIST" ]]; then
    pass "Plist present: $PLIST"
else
    fail "Plist missing: $PLIST — run 'make install-launchagent'"
fi

if launchctl list | grep -q "com.clipster.daemon"; then
    pass "LaunchAgent is loaded (com.clipster.daemon visible in launchctl list)"
else
    fail "LaunchAgent not loaded — run: launchctl bootstrap gui/\$(id -u) $PLIST"
fi

# ─── 3. Daemon running ────────────────────────────────────────────────────────

header "3. Daemon process"

if pgrep -x clipsterd > /dev/null; then
    DAEMON_PID=$(pgrep -x clipsterd)
    pass "clipsterd is running (PID $DAEMON_PID)"
else
    fail "clipsterd process not found — check $LOG for errors"
fi

# ─── 4. Log output ────────────────────────────────────────────────────────────

header "4. Startup log"

if [[ -f "$LOG" ]]; then
    if grep -q "clipsterd" "$LOG"; then
        pass "Log file exists and contains startup output"
        echo "    Last 5 log lines:"
        tail -5 "$LOG" | sed 's/^/    /'
    else
        warn "Log file exists but has no clipsterd output — may not have started yet"
    fi
else
    fail "Log file not found: $LOG"
fi

# ─── 5. Clipboard capture ─────────────────────────────────────────────────────

header "5. Clipboard capture"

UNIQUE="clipster-verify-$(date +%s)"
echo -n "$UNIQUE" | pbcopy
echo "  Copied test string to clipboard: $UNIQUE"
echo "  Waiting 400ms for poll + debounce..."
sleep 0.4

if [[ -f "$DB" ]]; then
    pass "Database file created: $DB"
    # Use sqlite3 to check for our entry
    if command -v sqlite3 &>/dev/null; then
        COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM entries WHERE content LIKE '%$UNIQUE%'" 2>/dev/null || echo "0")
        if [[ "$COUNT" -gt 0 ]]; then
            pass "Test entry found in database (count: $COUNT)"
        else
            fail "Test entry NOT found in database — clipboard capture may be broken"
            echo "  Manual check:"
            echo "    sqlite3 \"$DB\" 'SELECT id, content_type, preview, created_at FROM entries ORDER BY created_at DESC LIMIT 5;'"
        fi
    else
        warn "sqlite3 not found — cannot verify entry in DB. Install Xcode Command Line Tools."
    fi
else
    fail "Database file not created — daemon may not be writing"
fi

# ─── 6. Crash recovery (KeepAlive) ────────────────────────────────────────────

header "6. Crash recovery (KeepAlive)"

if pgrep -x clipsterd > /dev/null; then
    OLD_PID=$(pgrep -x clipsterd)
    echo "  Killing clipsterd (PID $OLD_PID) with SIGKILL..."
    kill -9 "$OLD_PID" 2>/dev/null || true
    echo "  Waiting up to 10s for launchd to restart..."

    RESTARTED=false
    for i in $(seq 1 10); do
        sleep 1
        if pgrep -x clipsterd > /dev/null; then
            NEW_PID=$(pgrep -x clipsterd)
            if [[ "$NEW_PID" != "$OLD_PID" ]]; then
                pass "Daemon restarted by launchd (new PID $NEW_PID) after ${i}s"
                RESTARTED=true
                break
            fi
        fi
    done

    if [[ "$RESTARTED" != "true" ]]; then
        fail "Daemon did NOT restart within 10s — KeepAlive may not be working"
    fi
else
    warn "clipsterd not running — skipping crash recovery test"
fi

# ─── 7. TCC clipboard access check ───────────────────────────────────────────

header "7. TCC / Clipboard privacy"

echo "  Checking for TCC-related log entries..."
if [[ -f "$LOG" ]] && grep -qi "tcc\|denied\|not permitted\|privacy" "$LOG" 2>/dev/null; then
    warn "Possible TCC issue in log — review $LOG"
    echo "  If macOS prompted for clipboard access permission, grant it in:"
    echo "  System Settings → Privacy & Security → Paste"
    echo "  Then restart the daemon: launchctl kickstart -k gui/\$(id -u)/com.clipster.daemon"
else
    pass "No TCC-related errors detected in log"
    echo "  NOTE: TCC clipboard prompt may appear on first copy in any app."
    echo "  If clipboard data stops being captured, check System Settings → Privacy."
fi

# ─── 8. Summary ───────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════"
echo "Phase 0 Verification Summary"
echo "══════════════════════════════════"
echo "  PASS: $PASS"
echo "  WARN: $WARN"
echo "  FAIL: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "  ✗ Phase 0 GATE: NOT PASSED — $FAIL failure(s) must be resolved before Phase 1."
    echo "  Escalate blockers to Alfred."
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo "  ⚠ Phase 0 GATE: PASSED WITH WARNINGS — review warnings before Phase 1."
    echo "  Notarisation step must still be run: 'make notarise'"
else
    echo "  ✓ Phase 0 GATE: PASSED (daemon checks)"
    echo "  Remaining: run 'make notarise' and verify Gatekeeper on clean macOS install."
fi
