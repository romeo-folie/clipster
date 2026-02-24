---
name: clipster-phase1
status: in-progress
created: 2026-02-24T13:00:00Z
progress: 0%
prd: ~/superteam-ops/outbox/clipster-cli-prd-v1.md
github: https://github.com/romeo-folie/clipster/issues?q=label%3Aphase-1
---

# Epic: Clipster Phase 1 — Core Daemon

## Overview
Full implementation of `clipsterd` (Swift daemon) and `clipster` (Go CLI) core functionality.
Phase 0 established the prototype skeleton. Phase 1 completes all PRD §13 Phase 1 deliverables.

## Architecture Decisions
- `ClipsterCore` library target extended (Phase 0 structure already clean per §14.1)
- Config parsed at startup only; SIGHUP hot-reload deferred to v2 (PRD §12)
- IPC protocol versioned from v1; breaking changes bump version field
- Go CLI uses `modernc.org/sqlite` (pure Go, no CGO) for SQLite fallback reads
- Bubble Tea deferred to Phase 2 — Phase 1 CLI is commands-only (no interactive TUI)

## Issues
| # | Title | Status |
|---|-------|--------|
| #1 | Full content-type detection + source attribution (clipsterd) | open |
| #2 | TOML config file parsing (clipsterd) | open |
| #3 | IPC Unix socket server (clipsterd) | open |
| #4 | Go CLI scaffold + IPC client + basic commands | open |
| #5 | clipster daemon status\|start\|stop\|restart | open |

## Implementation Order
1. #2 Config (no deps, unlocks suppress_bundles for #1)
2. #1 Content-type detection (depends on config for suppress_bundles)
3. #3 IPC server (depends on complete clipsterd for all commands)
4. #4 Go CLI scaffold (depends on #3 socket contract)
5. #5 daemon commands (depends on #4 CLI scaffold)

## Success Criteria
- All Phase 1 ACs in PRD §10 pass
- `make test` clean before every commit
- No skipped review issues without documentation
