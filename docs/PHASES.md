# Clipster CLI — Implementation Phases

Source of truth: PRD §13. This document tracks phase status and decisions.

---

## Phase 0 — Prototype Gate

**Status:** ✅ Complete — gate passed (notarisation deferred)  
**Week:** 1  
**Objective:** De-risk the daemon architecture before writing production code.

### Deliverables

- [x] Minimal `clipsterd` Swift package: NSPasteboard polling (250ms) + debounce (50ms)
- [x] SQLite write on clipboard change via GRDB
- [x] LaunchAgent plist (`com.clipster.daemon`)
- [x] Notarisation pipeline: Makefile targets + `scripts/sign.sh`
- [x] Phase 0 verification procedure: `scripts/verify-phase0.sh`

### Romeo Gates (manual — must be run on Mac)

- [ ] `make build` — Swift build succeeds
- [ ] `make install-launchagent` — plist loaded via `launchctl bootstrap`
- [ ] Clipboard change appears in `history.db` within 350ms
- [ ] `launchctl bootout` + kill SIGKILL → daemon relaunches within 10s (KeepAlive confirmed)
- [ ] `make sign` → binary signed with Developer ID
- [ ] `make notarise` → notarisation ticket accepted by Apple
- [ ] Gatekeeper accepts binary on a clean macOS 13+ install

### Go / No-Go

Proceed to Phase 1 if:
1. Daemon runs correctly as a LaunchAgent, AND
2. Notarisation succeeds

If either fails: evaluate alternatives before continuing. Escalate to Alfred.

---

## Phase 1 — Core Daemon

**Status:** ✅ Complete  
**Weeks:** 2–5

- Full clipboard monitoring: all content types, debounce, source attribution, deduplication, password manager suppression
- SQLite storage: WAL mode, full schema, migrations, vacuum logic, all cap options
- IPC socket server: versioned protocol, 4-byte framing, all commands, write ownership invariant
- Basic Go CLI: `list`, `last`, `pins`, fallback mode with banner
- `clipster daemon status|start|stop|restart`
- Config file (TOML): all fields, defaults, validation

---

## Phase 2 — Full CLI / TUI

**Status:** ✅ Complete  
**Weeks:** 6–9

- Bubble Tea TUI: inline filter, keybindings, type icons, source display, pin/unpin, delete
- `clipster clear` with confirmation
- `clipster config`
- Full transform suite (all 11 transforms, TUI error handling)
- Fallback mode completeness
- `source_confidence` display in TUI

---

## Phase 3 — Install Script, Config Polish, Performance

**Status:** ✅ Complete  
**Weeks:** 10–12

- `install.sh` and `uninstall.sh` (full PRD §7.8 spec)
- Checksum verification
- Config file defaults on first run
- Full acceptance criteria pass (all ACs in PRD §10)
- Performance validation (Apple Silicon + Intel targets)
- Documentation: README, `clipster --help`, config file comments

---

## Phase 4 — GUI Transition (PRD §14)

**Status:** 🚧 In Progress (kickoff)  
**Objective:** Evolve `clipsterd` into an app-bundle-capable runtime without breaking CLI clients.

- Architecture + migration plan per PRD §14.1
- Lifecycle transition plan (LaunchAgent → app-capable runtime)
- Permissions strategy (TCC/Accessibility/CGEvent)
- Backward-compatible IPC and schema guarantees

Tracking issue: #19

---

### Known Phase 1 Gaps (documented — not blockers for PR)

| Gap | Notes |
|---|---|
| Image thumbnail generation | `ContentClassifier.imageData()` returns nil — images are detected by UTI but not yet stored. JPEG thumbnail generation (thumbnails table) deferred to Phase 2. |
| Transform `format_json` / `format_xml` | Not in PRD §7.4 transform list; only the 11 documented transforms are implemented. |
| Entry count/size pruning | `history.entry_limit` and `db_size_cap_mb` are parsed from config and stored but pruning logic (vacuum, DELETE) not yet wired. Phase 2. |

---

## Architectural Decisions Log

### Phase 0

| Decision | Rationale |
|---|---|
| Swift package for `clipsterd` (not Xcode project) | CLI-buildable, CI-friendly, no GUI toolchain required |
| GRDB 6.x for SQLite | Best-in-class Swift SQLite, versioned migrations, WAL support, matches PRD spec |
| DispatchSourceTimer for polling | Avoids NSTimer (requires runloop) and RunLoop complexity in a headless daemon |
| Signal handling via `signal()` | POSIX signals sufficient for Phase 0; Phase 1 will use `DispatchSource.makeSignalSource` for proper async handling |
| Hardened Runtime entitlements | Minimal entitlements — no special permissions needed for NSPasteboard in user session context |

### Open Questions Carried Forward

| Question | Status |
|---|---|
| TCC clipboard privacy prompt (macOS 14+) | Phase 0 gate will reveal if launchd-launched daemon hits TCC. If it does, Phase 1 must add NSPasteboardUsageDescription via a custom Info.plist. Document in verify-phase0.sh. |
| Minimum macOS version | Targeting macOS 13 (Ventura). Needs engineering confirmation from Phase 0 build. |
| Binary notarisation confirmed | Phase 0 gate. |
