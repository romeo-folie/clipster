#!/usr/bin/env bash
# install.sh — Clipster install script (PRD §7.8 / AC-INST-01 through AC-INST-05)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/romeo-folie/clipster/main/scripts/install.sh | bash
# Or locally:
#   bash scripts/install.sh [--build-from-source]
#
# Options:
#   --build-from-source   Build both binaries from source instead of downloading
#   --prefix <path>       Install prefix (default: /usr/local)
#   --skip-launchagent    Install binaries only, do not load LaunchAgent

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
APP_SUPPORT_DIR="$HOME/Library/Application Support/Clipster"
CONFIG_DIR="$HOME/.config/clipster"
PLIST="$LAUNCH_AGENTS_DIR/com.clipster.daemon.plist"
REPO="romeo-folie/clipster"
BUILD_FROM_SOURCE=false
SKIP_LAUNCHAGENT=false

for arg in "$@"; do
    case "$arg" in
        --build-from-source) BUILD_FROM_SOURCE=true ;;
        --skip-launchagent)  SKIP_LAUNCHAGENT=true  ;;
        --prefix) PREFIX="$2"; BIN_DIR="$PREFIX/bin"; shift ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────

info()    { echo "  → $*"; }
success() { echo "  ✓ $*"; }
fail()    { echo "  ✗ ERROR: $*" >&2; exit 1; }

detect_arch() {
    case "$(uname -m)" in
        arm64)  echo "arm64"   ;;
        x86_64) echo "x86_64"  ;;
        *)      fail "Unsupported architecture: $(uname -m)" ;;
    esac
}

# ─── Requirements ─────────────────────────────────────────────────────────────

echo ""
echo "Clipster Installer"
echo "────────────────────────────────"

# macOS required
if [[ "$(uname)" != "Darwin" ]]; then
    fail "Clipster requires macOS."
fi

# Minimum macOS 13
OS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if (( OS_VERSION < 13 )); then
    fail "Clipster requires macOS 13 (Ventura) or later. Found: $(sw_vers -productVersion)"
fi

# ─── Build or Download ───────────────────────────────────────────────────────

ARCH=$(detect_arch)
TMPDIR_CLIPSTER=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CLIPSTER"' EXIT

if $BUILD_FROM_SOURCE; then
    info "Building from source..."

    # Verify build tools
    command -v swift  >/dev/null 2>&1 || fail "swift not found. Install Xcode Command Line Tools: xcode-select --install"
    command -v go     >/dev/null 2>&1 || fail "go not found. Install from https://go.dev/dl"

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

    info "Building clipsterd..."
    (cd "$PROJECT_DIR/clipsterd" && swift build -c release 2>&1 | tail -3)
    cp "$PROJECT_DIR/clipsterd/.build/release/clipsterd" "$TMPDIR_CLIPSTER/clipsterd"

    info "Building clipster..."
    (cd "$PROJECT_DIR/clipster-client" && go build -ldflags="-s -w" -o "$TMPDIR_CLIPSTER/clipster" ./cmd/clipster)

else
    # Download pre-built binaries from latest GitHub release
    info "Fetching latest release info..."
    command -v curl >/dev/null 2>&1 || fail "curl is required."

    LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"tag_name"' | cut -d'"' -f4)
    [[ -n "$LATEST" ]] || fail "Could not fetch latest release from GitHub."
    info "Latest release: $LATEST"

    BASE_URL="https://github.com/$REPO/releases/download/$LATEST"
    CLIPSTERD_BIN="clipsterd-darwin-$ARCH"
    CLIPSTER_BIN="clipster-darwin-$ARCH"
    CLIPSTERD_SHA="clipsterd-darwin-$ARCH.sha256"
    CLIPSTER_SHA="clipster-darwin-$ARCH.sha256"

    info "Downloading clipsterd ($ARCH)..."
    curl -fsSL "$BASE_URL/$CLIPSTERD_BIN"    -o "$TMPDIR_CLIPSTER/clipsterd"
    curl -fsSL "$BASE_URL/$CLIPSTERD_SHA"    -o "$TMPDIR_CLIPSTER/clipsterd.sha256"

    info "Downloading clipster ($ARCH)..."
    curl -fsSL "$BASE_URL/$CLIPSTER_BIN"     -o "$TMPDIR_CLIPSTER/clipster"
    curl -fsSL "$BASE_URL/$CLIPSTER_SHA"     -o "$TMPDIR_CLIPSTER/clipster.sha256"

    # ─── Checksum verification ─────────────────────────────────────────────
    info "Verifying checksums..."
    (cd "$TMPDIR_CLIPSTER" && \
        sed -i '' "s|$CLIPSTERD_BIN|clipsterd|" clipsterd.sha256 && \
        shasum -a 256 -c clipsterd.sha256 > /dev/null 2>&1) || \
        fail "clipsterd checksum verification failed. Aborting for security."
    (cd "$TMPDIR_CLIPSTER" && \
        sed -i '' "s|$CLIPSTER_BIN|clipster|" clipster.sha256 && \
        shasum -a 256 -c clipster.sha256 > /dev/null 2>&1) || \
        fail "clipster checksum verification failed. Aborting for security."
    success "Checksums verified"
fi

# ─── Install binaries ─────────────────────────────────────────────────────────

info "Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"
install -m 755 "$TMPDIR_CLIPSTER/clipsterd" "$BIN_DIR/clipsterd"
install -m 755 "$TMPDIR_CLIPSTER/clipster"  "$BIN_DIR/clipster"
success "Installed: $BIN_DIR/clipsterd"
success "Installed: $BIN_DIR/clipster"

# ─── App Support directory ────────────────────────────────────────────────────

mkdir -p "$APP_SUPPORT_DIR"

# ─── Default config ───────────────────────────────────────────────────────────

if [[ ! -f "$CONFIG_DIR/config.toml" ]]; then
    info "Creating default config at $CONFIG_DIR/config.toml..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.toml" << 'TOML'
# Clipster configuration
# Changes take effect after: clipster daemon restart

[history]
entry_limit = 500          # 100 | 500 | 1000 | 0 (no count limit)
db_size_cap_mb = 500       # max DB size in MB: 100 | 250 | 500 | 1000

[privacy]
suppress_bundles = [
  "com.1password.1password",
  "com.bitwarden.desktop",
  "com.dashlane.dashlane",
  "com.lastpass.LastPass"
]

[daemon]
log_level = "info"         # debug | info | warn | error
TOML
    success "Config created"
else
    info "Config already exists — not overwriting: $CONFIG_DIR/config.toml"
fi

# ─── LaunchAgent ──────────────────────────────────────────────────────────────

if ! $SKIP_LAUNCHAGENT; then
    info "Installing LaunchAgent..."

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PLIST_SRC="$SCRIPT_DIR/../support/com.clipster.daemon.plist"

    # If plist source not present (e.g. curl install), write it inline
    mkdir -p "$LAUNCH_AGENTS_DIR"
    sed -e "s|REPLACE_WITH_HOME|$HOME|g" \
        -e "s|/usr/local/bin/clipsterd|$BIN_DIR/clipsterd|g" \
        "$PLIST_SRC" 2>/dev/null > "$PLIST" || \
    cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clipster.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/clipsterd</string>
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
        <string>$HOME</string>
    </dict>
</dict>
</plist>
PLIST_EOF

    info "Loading LaunchAgent..."
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || \
        launchctl load "$PLIST" 2>/dev/null || true

    # Verify it loaded
    sleep 1
    if launchctl list | grep -q "com.clipster.daemon"; then
        success "LaunchAgent loaded — clipsterd running"
    else
        echo "  ⚠ LaunchAgent may not have loaded — check: launchctl list | grep clipster"
        echo "    Manual load: launchctl bootstrap gui/\$(id -u) $PLIST"
    fi
fi

# ─── PATH check ───────────────────────────────────────────────────────────────

if ! echo "$PATH" | grep -q "$BIN_DIR"; then
    echo ""
    echo "  ⚠ $BIN_DIR is not in your PATH."
    echo "  Add this to your shell profile (.zshrc / .bashrc):"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────"
echo "✓ Clipster installed successfully"
echo ""
echo "Quick start:"
echo "  clipster              # open TUI"
echo "  clipster last         # last clipboard entry"
echo "  clipster daemon status"
echo ""
echo "Logs: tail -f /tmp/clipsterd.log"
echo "Config: $CONFIG_DIR/config.toml"
echo ""
