#!/usr/bin/env bash
# uninstall.sh — Clipster uninstall script (PRD §7.8 / AC-INST-05)
#
# Usage:
#   bash scripts/uninstall.sh [--purge-data]
#
# Options:
#   --purge-data   Also remove ~/Library/Application Support/Clipster/ (history + DB)
#                  Config at ~/.config/clipster/ is ALWAYS preserved unless --purge-config.
#   --purge-config Also remove ~/.config/clipster/config.toml
#   --force        Skip all confirmation prompts

set -euo pipefail

PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
APP_SUPPORT_DIR="$HOME/Library/Application Support/Clipster"
CONFIG_DIR="$HOME/.config/clipster"
PLIST="$LAUNCH_AGENTS_DIR/com.clipster.daemon.plist"
LAUNCHD_SVC="gui/$(id -u)/com.clipster.daemon"

PURGE_DATA=false
PURGE_CONFIG=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --purge-data)   PURGE_DATA=true   ;;
        --purge-config) PURGE_CONFIG=true ;;
        --force)        FORCE=true        ;;
    esac
done

info()    { echo "  → $*"; }
success() { echo "  ✓ $*"; }
warn()    { echo "  ⚠ $*"; }

confirm() {
    $FORCE && return 0
    read -r -p "  $* [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

echo ""
echo "Clipster Uninstaller"
echo "────────────────────────────────"
echo ""

# ─── Stop daemon ─────────────────────────────────────────────────────────────

info "Stopping daemon..."
launchctl bootout "$LAUNCHD_SVC" 2>/dev/null || \
    launchctl unload "$PLIST" 2>/dev/null || true

# Wait for process to exit
for _ in $(seq 1 5); do
    pgrep -x clipsterd >/dev/null 2>&1 || break
    sleep 0.5
done

if pgrep -x clipsterd >/dev/null 2>&1; then
    warn "clipsterd still running — sending SIGTERM"
    pkill -TERM clipsterd 2>/dev/null || true
    sleep 1
fi
success "Daemon stopped"

# ─── Remove plist ─────────────────────────────────────────────────────────────

if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST"
    success "Removed LaunchAgent plist"
fi

# ─── Remove binaries ──────────────────────────────────────────────────────────

for bin in clipsterd clipster; do
    if [[ -f "$BIN_DIR/$bin" ]]; then
        rm -f "$BIN_DIR/$bin"
        success "Removed $BIN_DIR/$bin"
    fi
done

# ─── User data (optional) ─────────────────────────────────────────────────────

if $PURGE_DATA; then
    if [[ -d "$APP_SUPPORT_DIR" ]]; then
        if confirm "Delete clipboard history at $APP_SUPPORT_DIR? This cannot be undone."; then
            rm -rf "$APP_SUPPORT_DIR"
            success "Removed $APP_SUPPORT_DIR"
        else
            info "Kept $APP_SUPPORT_DIR"
        fi
    fi
else
    info "Clipboard history preserved: $APP_SUPPORT_DIR"
    info "  (remove with: rm -rf \"$APP_SUPPORT_DIR\")"
fi

# ─── Config (optional) ────────────────────────────────────────────────────────

if $PURGE_CONFIG; then
    if [[ -f "$CONFIG_DIR/config.toml" ]]; then
        if confirm "Delete config at $CONFIG_DIR/config.toml?"; then
            rm -rf "$CONFIG_DIR"
            success "Removed $CONFIG_DIR"
        else
            info "Kept $CONFIG_DIR"
        fi
    fi
else
    info "Config preserved: $CONFIG_DIR/config.toml"
    info "  (remove with: rm -rf \"$CONFIG_DIR\")"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────"
echo "✓ Clipster uninstalled"
echo ""
