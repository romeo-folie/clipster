#!/usr/bin/env bash
# repo-init.sh — One-time setup: init git repo, create GitHub repo, first commit.
#
# Run this ONCE from the clipster/ directory on Romeo's Mac.
# Requires: gh CLI authenticated (gh auth status)
#
# Usage:
#   cd ~/superteam-ops/projects/clipster
#   bash scripts/repo-init.sh

set -euo pipefail

REPO="romeo-folie/clipster"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "→ Working directory: $DIR"
cd "$DIR"

# Verify gh is authenticated
echo "→ Checking gh auth..."
gh auth status

# Copy PRD from superteam-ops
echo "→ Copying PRD..."
cp ~/superteam-ops/outbox/clipster-cli-prd-v1.md docs/PRD.md

# Make scripts executable
echo "→ Setting script permissions..."
chmod +x scripts/*.sh

# Init git
echo "→ Initialising git..."
git init
git checkout -b main

# Create private GitHub repo
echo "→ Creating private GitHub repo: $REPO"
gh repo create "$REPO" \
    --private \
    --description "macOS clipboard manager — headless daemon + Go TUI" \
    --source=. \
    --remote=origin

# Initial commit
echo "→ Initial commit (PRD + phase plan)..."
git add .
git commit -m "chore: initial commit — PRD + Phase 0 implementation

Phase 0 deliverables:
- clipsterd Swift package (ClipsterCore + thin executable)
- NSPasteboard polling (250ms) + debounce (50ms)
- SQLite storage via GRDB (full PRD §7.2 schema)
- LaunchAgent plist (com.clipster.daemon)
- Notarisation pipeline: scripts/sign.sh + Makefile targets
- Phase 0 verification procedure: scripts/verify-phase0.sh
- Tests: DatabaseTests + ClipboardMonitorTests

Closes Phase 0 code deliverables.
Pending Romeo: build gate, LaunchAgent verify, crash recovery, notarisation.

PRD: docs/PRD.md (Pam, 2026-02-24)"

git push -u origin main

echo ""
echo "✓ Repo created and pushed: https://github.com/$REPO"
echo ""
echo "Next steps — Phase 0 gate (run on Mac):"
echo "  1. make build"
echo "  2. make test"
echo "  3. make install && make install-launchagent"
echo "  4. make verify-phase0"
echo "  5. Set DEVELOPER_ID, APPLE_ID, TEAM_ID, APP_PASSWORD"
echo "  6. make notarise"
echo "  7. Verify Gatekeeper on clean macOS install"
echo ""
echo "Report back to Alfred when Phase 0 gate is complete."
