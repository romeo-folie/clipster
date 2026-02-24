# Makefile — Clipster CLI
# Targets are designed to be run on macOS (arm64 or x86_64).
# Phase 0 covers: build, test, install, sign, notarise.

.DEFAULT_GOAL := help

BINARY_NAME   := clipsterd
BUILD_DIR     := clipsterd/.build/release
BINARY        := $(BUILD_DIR)/$(BINARY_NAME)
INSTALL_PATH  := /usr/local/bin/$(BINARY_NAME)
PLIST_SRC     := support/com.clipster.daemon.plist
PLIST_DEST    := $(HOME)/Library/LaunchAgents/com.clipster.daemon.plist
LAUNCHD_SVC   := gui/$(shell id -u)/com.clipster.daemon

# ─── Build ────────────────────────────────────────────────────────────────────

.PHONY: build
build: ## Build clipsterd (release) for the current architecture
	@echo "→ Building clipsterd..."
	cd clipsterd && swift build -c release
	@echo "✓ Built: $(BINARY)"
	@file $(BINARY)

.PHONY: build-debug
build-debug: ## Build clipsterd (debug)
	cd clipsterd && swift build
	@echo "✓ Debug build: clipsterd/.build/debug/$(BINARY_NAME)"

.PHONY: build-universal
build-universal: ## Build universal binary (arm64 + x86_64)
	@echo "→ Building arm64..."
	cd clipsterd && swift build -c release --arch arm64
	@echo "→ Building x86_64..."
	cd clipsterd && swift build -c release --arch x86_64
	@echo "→ Creating universal binary..."
	mkdir -p dist
	lipo -create \
		clipsterd/.build/arm64-apple-macosx/release/$(BINARY_NAME) \
		clipsterd/.build/x86_64-apple-macosx/release/$(BINARY_NAME) \
		-output dist/$(BINARY_NAME)-universal
	@echo "✓ Universal binary: dist/$(BINARY_NAME)-universal"

# ─── Test ─────────────────────────────────────────────────────────────────────

.PHONY: test
test: ## Run all Swift tests
	@echo "→ Running tests..."
	cd clipsterd && swift test
	@echo "✓ All tests passed"

.PHONY: test-verbose
test-verbose: ## Run tests with verbose output
	cd clipsterd && swift test --verbose

# ─── Install ──────────────────────────────────────────────────────────────────

.PHONY: install
install: build ## Install clipsterd to /usr/local/bin
	@echo "→ Installing $(BINARY_NAME) to $(INSTALL_PATH)..."
	install -m 755 $(BINARY) $(INSTALL_PATH)
	@echo "✓ Installed: $(INSTALL_PATH)"

.PHONY: install-launchagent
install-launchagent: ## Write plist and load LaunchAgent via launchctl
	@echo "→ Writing LaunchAgent plist..."
	sed -e "s|REPLACE_WITH_HOME|$(HOME)|g" \
		$(PLIST_SRC) > $(PLIST_DEST)
	@echo "  Written: $(PLIST_DEST)"
	@echo "→ Loading LaunchAgent..."
	launchctl bootstrap $(LAUNCHD_SVC) $(PLIST_DEST) 2>/dev/null || \
		launchctl load $(PLIST_DEST)
	@echo "✓ LaunchAgent loaded: com.clipster.daemon"
	@sleep 1
	@launchctl list | grep com.clipster.daemon || echo "  Warning: service not visible in launchctl list yet"

.PHONY: uninstall-launchagent
uninstall-launchagent: ## Unload and remove LaunchAgent
	@echo "→ Unloading LaunchAgent..."
	launchctl bootout $(LAUNCHD_SVC) $(PLIST_DEST) 2>/dev/null || \
		launchctl unload $(PLIST_DEST) 2>/dev/null || true
	rm -f $(PLIST_DEST)
	@echo "✓ LaunchAgent removed"

.PHONY: uninstall
uninstall: uninstall-launchagent ## Unload LaunchAgent and remove binary
	rm -f $(INSTALL_PATH)
	@echo "✓ $(BINARY_NAME) removed from $(INSTALL_PATH)"
	@echo "  User data preserved: ~/Library/Application Support/Clipster/"
	@echo "  Config preserved:    ~/.config/clipster/config.toml"

# ─── Daemon control ──────────────────────────────────────────────────────────

.PHONY: daemon-start
daemon-start: ## Start the daemon via launchctl kickstart
	launchctl kickstart $(LAUNCHD_SVC)

.PHONY: daemon-stop
daemon-stop: ## Stop the daemon via launchctl kill
	launchctl kill SIGTERM $(LAUNCHD_SVC)

.PHONY: daemon-restart
daemon-restart: ## Restart the daemon
	launchctl kill SIGTERM $(LAUNCHD_SVC)
	@sleep 2
	@echo "✓ Daemon restarted (launchd will restart automatically due to KeepAlive)"

.PHONY: daemon-status
daemon-status: ## Show daemon status
	@launchctl list | grep com.clipster.daemon || echo "com.clipster.daemon: not loaded"
	@pgrep -x clipsterd && echo "clipsterd PID: $$(pgrep -x clipsterd)" || echo "clipsterd: not running"

.PHONY: logs
logs: ## Tail daemon logs
	tail -f /tmp/clipsterd.log

# ─── Sign & Notarise ─────────────────────────────────────────────────────────

.PHONY: sign
sign: ## Sign the release binary with Developer ID (set DEVELOPER_ID env var)
	./scripts/sign.sh sign

.PHONY: notarise
notarise: ## Sign + notarise the release binary (set DEVELOPER_ID, APPLE_ID, TEAM_ID, APP_PASSWORD)
	./scripts/sign.sh notarise

.PHONY: verify-signature
verify-signature: ## Verify binary signature and Gatekeeper acceptance
	./scripts/sign.sh verify

# ─── Phase 0 Gate ────────────────────────────────────────────────────────────

.PHONY: verify-phase0
verify-phase0: ## Run Phase 0 gate verification (run after install + install-launchagent)
	./scripts/verify-phase0.sh

# ─── Clean ───────────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove build artifacts
	cd clipsterd && swift package clean
	rm -rf dist/

# ─── Help ────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@echo "Clipster CLI — Makefile targets"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-25s %s\n", $$1, $$2}'
	@echo ""
	@echo "Phase 0 workflow:"
	@echo "  1. make build"
	@echo "  2. make test"
	@echo "  3. make install"
	@echo "  4. make install-launchagent"
	@echo "  5. make verify-phase0"
	@echo "  6. make notarise  (requires DEVELOPER_ID, APPLE_ID, TEAM_ID, APP_PASSWORD)"
