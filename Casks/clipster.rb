cask "clipster" do
  version "0.1.0"
  # Update sha256 after each release:
  #   shasum -a 256 dist/Clipster-<version>.dmg
  sha256 "PLACEHOLDER_SHA256_UPDATE_BEFORE_RELEASE"

  url "https://github.com/romeo-folie/clipster/releases/download/v#{version}/Clipster-#{version}.dmg"

  name "Clipster"
  desc "Modern macOS clipboard manager — menu bar GUI and CLI/TUI"
  homepage "https://github.com/romeo-folie/clipster"

  # Clipster requires macOS 13 Ventura or later (per PRD §13 Phase 0 gate).
  depends_on macos: ">= :ventura"

  app "Clipster.app"

  # Post-install: load the clipsterd LaunchAgent if present in the bundle.
  # (Phase 3.x — wired when DMG bundles the daemon LaunchAgent plist)

  # Clean uninstall: remove app data, preferences, and socket directory.
  # Socket is transient but may persist if the daemon was killed uncleanly.
  zap trash: [
    "~/Library/Application Support/Clipster",
    "~/Library/Preferences/com.clipster.app.plist",
    "~/Library/LaunchAgents/com.clipster.daemon.plist",
  ]
end
