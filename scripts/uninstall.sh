#!/usr/bin/env bash
# uninstall.sh — Clipster uninstaller
# PRD §7.8.2
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
PLIST_LABEL="com.clipster.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
DAEMON_BIN="/usr/local/bin/clipsterd"
CLI_LOCAL_BIN="$HOME/.local/bin/clipster"
CLI_FALLBACK_BIN="/usr/local/bin/clipster"
DATA_DIR="$HOME/Library/Application Support/Clipster"
CONFIG_DIR="$HOME/.config/clipster"

PURGE=false

# ── Helpers ────────────────────────────────────────────────────────────────────
info()   { printf "  %s\n" "$*"; }
ok()     { printf "✓ %s\n" "$*"; }
warn()   { printf "⚠ %s\n" "$*" >&2; }
removed(){ printf "  removed: %s\n" "$*"; }
kept()   { printf "  kept:    %s\n" "$*"; }

usage() {
    cat << EOF
Usage: uninstall.sh [--purge]

Options:
  --purge   Also remove user data (history.db, config.toml, all app data directories)
            WARNING: This is irreversible.
EOF
    exit 1
}

# ── Parse flags ────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=true ;;
        -h|--help) usage ;;
        *) warn "Unknown argument: $arg"; usage ;;
    esac
done

printf "Uninstalling Clipster...\n\n"

# ── Step 1: Unload LaunchAgent ─────────────────────────────────────────────────
info "Stopping daemon (LaunchAgent)..."
if [ -f "$PLIST_PATH" ]; then
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null && ok "Daemon stopped" || warn "Daemon was not running (OK)"
else
    warn "LaunchAgent plist not found — daemon may not be installed"
fi

# Belt-and-suspenders: kill any running clipsterd
if pgrep -x clipsterd > /dev/null 2>&1; then
    pkill -x clipsterd 2>/dev/null || true
    sleep 1
fi

# ── Step 2: Remove plist ───────────────────────────────────────────────────────
if [ -f "$PLIST_PATH" ]; then
    rm -f "$PLIST_PATH"
    removed "$PLIST_PATH"
fi

# ── Step 3: Remove daemon binary ──────────────────────────────────────────────
if [ -f "$DAEMON_BIN" ]; then
    if [ -w "$DAEMON_BIN" ]; then
        rm -f "$DAEMON_BIN"
    else
        sudo rm -f "$DAEMON_BIN"
    fi
    removed "$DAEMON_BIN"
fi

# ── Step 4: Remove CLI binary ─────────────────────────────────────────────────
CLI_REMOVED=false
if [ -f "$CLI_LOCAL_BIN" ]; then
    rm -f "$CLI_LOCAL_BIN"
    removed "$CLI_LOCAL_BIN"
    CLI_REMOVED=true
fi
if [ -f "$CLI_FALLBACK_BIN" ]; then
    if [ -w "$CLI_FALLBACK_BIN" ]; then
        rm -f "$CLI_FALLBACK_BIN"
    else
        sudo rm -f "$CLI_FALLBACK_BIN"
    fi
    removed "$CLI_FALLBACK_BIN"
    CLI_REMOVED=true
fi
if ! $CLI_REMOVED; then
    warn "clipster CLI binary not found (already removed?)"
fi

# ── Step 5 / 6: User data ────────────────────────────────────────────────────
printf "\n"
if $PURGE; then
    info "Purging user data..."
    if [ -d "$DATA_DIR" ]; then
        rm -rf "$DATA_DIR"
        removed "$DATA_DIR"
    fi
    if [ -d "$CONFIG_DIR" ]; then
        rm -rf "$CONFIG_DIR"
        removed "$CONFIG_DIR"
    fi
    ok "All Clipster data removed."
else
    info "User data preserved (run with --purge to remove):"
    [ -f "$DATA_DIR/history.db" ]           && kept "$DATA_DIR/history.db" || true
    [ -f "$CONFIG_DIR/config.toml" ]        && kept "$CONFIG_DIR/config.toml" || true
    [ -d "$DATA_DIR" ] && [ ! -f "$DATA_DIR/history.db" ] && kept "$DATA_DIR" || true
fi

# ── Step 7: Summary ───────────────────────────────────────────────────────────
printf "\n"
ok "Clipster uninstalled."
if ! $PURGE; then
    printf "  Your history and config are preserved in:\n"
    printf "    %s\n" "$DATA_DIR"
    printf "    %s\n" "$CONFIG_DIR"
    printf "  Run with --purge to remove all data.\n"
fi
