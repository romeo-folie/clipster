# Clipster CLI

A macOS clipboard manager for terminal-native workflows.

- **`clipsterd`** — headless Swift daemon (clipboard monitoring, SQLite storage, Unix socket IPC)
- **`clipster`** — Go TUI client (history viewer, transforms, CLI commands)

Free and open source. No GUI, no menu bar, no cloud sync.

---

## Status

**Phase 0 — Prototype Gate** (current)

Minimal `clipsterd` daemon: clipboard polling, SQLite storage, LaunchAgent.  
See [PHASES.md](PHASES.md) for the full phase plan.

---

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+

For notarisation:
- Apple Developer account (paid)
- Developer ID Application certificate

---

## Phase 0 — Build & Test

```sh
# Build clipsterd
make build

# Run tests
make test

# Install binary + LaunchAgent
make install
make install-launchagent

# Verify Phase 0 gate
make verify-phase0

# Sign + notarise (Phase 0 gate — requires Apple Developer creds)
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID12AB)"
export APPLE_ID="you@example.com"
export TEAM_ID="TEAMID12AB"
export APP_PASSWORD=$(security find-generic-password -s clipster-notarise -w)
make notarise
```

See `scripts/verify-phase0.sh` for the full gate procedure and `scripts/sign.sh` for signing details.

---

## Architecture

```
clipsterd (Swift, LaunchAgent)        clipster (Go, user binary)
├── ClipsterCore (library)            ├── TUI (Bubble Tea + Lip Gloss)
│   ├── ClipboardMonitor              ├── CLI commands
│   ├── Database (GRDB/SQLite)        └── Read-only SQLite fallback
│   └── Logging                             │
└── main.swift (entry point)               │
          │                                │
          └────── Unix socket IPC ─────────┘

Config:  ~/.config/clipster/config.toml
DB:      ~/Library/Application Support/Clipster/history.db
Socket:  ~/Library/Application Support/Clipster/clipster.sock
Log:     /tmp/clipsterd.log
```

`clipsterd` is the **sole write owner** of the SQLite database.  
`clipster` reads via IPC (daemon running) or direct SQLite read-only (fallback).

See `docs/PRD.md` for the full specification.

---

## GUI Phase

`clipsterd` is designed to evolve into a menu bar `.app` in the GUI phase —
same binary, AppKit UI layer added on top. The IPC contract, SQLite schema,
and TOML config are forward-compatible. See PRD §14.1.

---

## License

MIT
