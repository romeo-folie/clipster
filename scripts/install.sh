#!/usr/bin/env bash
# install.sh — Clipster installer
# Source: https://github.com/romeo-folie/clipster/releases/latest/download/install.sh
# PRD §7.8.1
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
REPO="romeo-folie/clipster"
MIN_MACOS_MAJOR=13
PLIST_LABEL="com.clipster.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
DAEMON_BIN="/usr/local/bin/clipsterd"
CLI_LOCAL_BIN="$HOME/.local/bin/clipster"
CLI_FALLBACK_BIN="/usr/local/bin/clipster"
SOCKET_PATH="$HOME/Library/Application Support/Clipster/clipster.sock"
SOCKET_RETRIES=5
SOCKET_WAIT=1  # seconds between retries

# Temp dir — cleaned up on exit
TMPDIR_INSTALL=$(mktemp -d)
cleanup() {
    rm -rf "$TMPDIR_INSTALL"
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────
info()  { printf "  %s\n" "$*"; }
ok()    { printf "✓ %s\n" "$*"; }
warn()  { printf "⚠ %s\n" "$*" >&2; }
fail()  { printf "✗ %s\n" "$*" >&2; exit 1; }

# Undo any partial install on failure
INSTALLED_DAEMON=false
INSTALLED_CLI=false
INSTALLED_PLIST=false
rollback() {
    # Disable ERR trap first to prevent re-entry if rollback commands fail.
    trap - ERR
    warn "Install failed — rolling back."
    if $INSTALLED_PLIST; then
        launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH" || true
    fi
    if $INSTALLED_DAEMON; then
        rm -f "$DAEMON_BIN" || true
    fi
    if $INSTALLED_CLI; then
        rm -f "$CLI_LOCAL_BIN" || true
        rm -f "$CLI_FALLBACK_BIN" || true
    fi
}
trap 'rollback' ERR

# ── Step 1: macOS version check ────────────────────────────────────────────────
info "Checking macOS version..."
MACOS_VER=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VER" | cut -d. -f1)
if [ "$MACOS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
    fail "Clipster requires macOS 13 Ventura or later. Found: ${MACOS_VER}"
fi
ok "macOS ${MACOS_VER} — OK"

# ── Step 2: Detect architecture ────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
    arm64)   ARCH_TAG="arm64" ;;
    x86_64)  ARCH_TAG="x86_64" ;;
    *)       fail "Unsupported architecture: ${ARCH}" ;;
esac
info "Architecture: ${ARCH_TAG}"

# ── Resolve latest release tag ─────────────────────────────────────────────────
info "Resolving latest release..."
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
if [ -z "$LATEST_TAG" ]; then
    fail "Could not determine latest release tag. Check your internet connection."
fi
info "Release: ${LATEST_TAG}"

BASE_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}"
DAEMON_ASSET="clipsterd-darwin-${ARCH_TAG}"
CLI_ASSET="clipster-darwin-${ARCH_TAG}"
CHECKSUMS_ASSET="checksums.txt"

# ── Step 3: Download binaries + checksums ─────────────────────────────────────
info "Downloading clipsterd..."
curl -fsSL "${BASE_URL}/${DAEMON_ASSET}" -o "${TMPDIR_INSTALL}/clipsterd" \
    || fail "Download failed: ${BASE_URL}/${DAEMON_ASSET}"

info "Downloading clipster..."
curl -fsSL "${BASE_URL}/${CLI_ASSET}" -o "${TMPDIR_INSTALL}/clipster" \
    || fail "Download failed: ${BASE_URL}/${CLI_ASSET}"

info "Downloading checksums..."
curl -fsSL "${BASE_URL}/${CHECKSUMS_ASSET}" -o "${TMPDIR_INSTALL}/checksums.txt" \
    || fail "Download failed: ${BASE_URL}/${CHECKSUMS_ASSET}"

# ── Step 6: Verify SHA-256 checksums (AC-INST-06) ─────────────────────────────
info "Verifying checksums..."
DAEMON_EXPECTED=$(grep "${DAEMON_ASSET}" "${TMPDIR_INSTALL}/checksums.txt" | awk '{print $1}')
CLI_EXPECTED=$(grep "${CLI_ASSET}" "${TMPDIR_INSTALL}/checksums.txt" | awk '{print $1}')

if [ -z "$DAEMON_EXPECTED" ] || [ -z "$CLI_EXPECTED" ]; then
    fail "Could not find expected checksums in checksums.txt for arch: ${ARCH_TAG}"
fi

DAEMON_ACTUAL=$(shasum -a 256 "${TMPDIR_INSTALL}/clipsterd" | awk '{print $1}')
CLI_ACTUAL=$(shasum -a 256 "${TMPDIR_INSTALL}/clipster" | awk '{print $1}')

if [ "$DAEMON_ACTUAL" != "$DAEMON_EXPECTED" ]; then
    fail "Checksum mismatch for clipsterd. Expected: ${DAEMON_EXPECTED}, Got: ${DAEMON_ACTUAL}"
fi
if [ "$CLI_ACTUAL" != "$CLI_EXPECTED" ]; then
    fail "Checksum mismatch for clipster. Expected: ${CLI_EXPECTED}, Got: ${CLI_ACTUAL}"
fi
ok "Checksums verified"

# ── Install daemon binary (AC-INST-01) ────────────────────────────────────────
info "Installing clipsterd → ${DAEMON_BIN}..."
if [ ! -w "$(dirname "$DAEMON_BIN")" ]; then
    sudo install -m 755 "${TMPDIR_INSTALL}/clipsterd" "$DAEMON_BIN" \
        || fail "Could not install clipsterd to ${DAEMON_BIN}"
else
    install -m 755 "${TMPDIR_INSTALL}/clipsterd" "$DAEMON_BIN" \
        || fail "Could not install clipsterd to ${DAEMON_BIN}"
fi
INSTALLED_DAEMON=true

# ── Install CLI binary (AC-INST-02) ───────────────────────────────────────────
CLI_BIN="$CLI_LOCAL_BIN"
CLI_BIN_DIR="$HOME/.local/bin"

if [ ! -d "$CLI_BIN_DIR" ]; then
    mkdir -p "$CLI_BIN_DIR"
fi

# Try ~/.local/bin; fall back to /usr/local/bin if not writable
if install -m 755 "${TMPDIR_INSTALL}/clipster" "$CLI_BIN" 2>/dev/null; then
    INSTALLED_CLI=true
elif [ -w "$(dirname "$CLI_FALLBACK_BIN")" ]; then
    CLI_BIN="$CLI_FALLBACK_BIN"
    install -m 755 "${TMPDIR_INSTALL}/clipster" "$CLI_BIN" \
        || fail "Could not install clipster CLI"
    INSTALLED_CLI=true
else
    sudo install -m 755 "${TMPDIR_INSTALL}/clipster" "$CLI_FALLBACK_BIN" \
        || fail "Could not install clipster CLI"
    CLI_BIN="$CLI_FALLBACK_BIN"
    INSTALLED_CLI=true
fi
info "CLI installed → ${CLI_BIN}"

# ── Step 4: Write LaunchAgent plist (AC-INST-03) ──────────────────────────────
info "Writing LaunchAgent plist..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clipster.daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/clipsterd</string>
    </array>

    <key>KeepAlive</key>
    <true/>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/clipsterd.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/clipsterd.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
</dict>
</plist>
EOF
INSTALLED_PLIST=true

# ── Step 5: Load LaunchAgent ───────────────────────────────────────────────────
info "Loading LaunchAgent..."
# Unload first in case an old version is present
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" \
    || fail "launchctl bootstrap failed. Check ${PLIST_PATH}."

# ── Step 6: Wait for daemon socket (AC-INST-04) ────────────────────────────────
info "Waiting for daemon socket..."
for i in $(seq 1 "${SOCKET_RETRIES}"); do
    if [ -S "$SOCKET_PATH" ]; then
        break
    fi
    sleep "$SOCKET_WAIT"
    if [ "$i" -eq "$SOCKET_RETRIES" ]; then
        fail "Daemon socket not available after ${SOCKET_RETRIES}s. Check /tmp/clipsterd.log."
    fi
done

# Get daemon PID
DAEMON_PID=$(pgrep -x clipsterd 2>/dev/null || echo "unknown")

# Disable rollback trap — install succeeded
trap - ERR

# ── Step 7: PATH reminder (AC-INST-05) ────────────────────────────────────────
if [[ "$CLI_BIN" == "$CLI_LOCAL_BIN" ]]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *)
            printf "\n"
            info "Add ~/.local/bin to your PATH:"
            printf "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc\n"
            printf "      source ~/.zshrc\n"
            ;;
    esac
fi

# ── Step 8: Success message ────────────────────────────────────────────────────
printf "\n"
ok "Clipster installed successfully."
printf "  daemon: clipsterd running (PID %s)\n" "$DAEMON_PID"
printf "  cli:    clipster at %s\n" "$CLI_BIN"
printf "  Run 'clipster' to open the TUI.\n"
