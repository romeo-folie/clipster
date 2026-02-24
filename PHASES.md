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

**Status:** Code complete — PR open, awaiting Romeo review  
**Weeks:** 2–5

- Full clipboard monitoring: all content types, debounce, source attribution, deduplication, password manager suppression
- SQLite storage: WAL mode, full schema, migrations, vacuum logic, all cap options
- IPC socket server: versioned protocol, 4-byte framing, all commands, write ownership invariant
- Basic Go CLI: `list`, `last`, `pins`, fallback mode with banner
- `clipster daemon status|start|stop|restart`
- Config file (TOML): all fields, defaults, validation

---

## Phase 2 — Full CLI / TUI

**Status:** Code complete — PR open, awaiting merge  
**Weeks:** 6–9

- Bubble Tea TUI: inline filter, keybindings, type icons, source display, pin/unpin, delete
- `clipster clear` with confirmation
- `clipster config`
- Full transform suite (all 11 transforms, TUI error handling)
- Fallback mode completeness
- `source_confidence` display in TUI

---

## Phase 3 — Install Script, Config Polish, Performance

**Status:** In progress (branch: phase-3-install-docs)  
**Weeks:** 10–12

### Issues
- [#11](https://github.com/romeo-folie/clipster/issues/11) — `install.sh` + `uninstall.sh`
- [#12](https://github.com/romeo-folie/clipster/issues/12) — Documentation
- [#13](https://github.com/romeo-folie/clipster/issues/13) — Config defaults audit + tests
- [#14](https://github.com/romeo-folie/clipster/issues/14) — Performance + CI

### Deliverables
- [x] `scripts/install.sh` — full PRD §7.8.1 (AC-INST-01–06, AC-INST-10)
- [x] `scripts/uninstall.sh` — full PRD §7.8.2 (AC-INST-07–09)
- [x] SHA-256 checksum verification in install script
- [x] Config TOML enhanced with descriptive comments for all fields
- [x] Config tests: AC-CFG-01 (all-keys present, idempotent create)
- [x] `.github/workflows/build.yml` — Swift + Go CI, shellcheck
- [x] Makefile: `bench-startup`, `bench-daemon` performance targets
- [x] Top-level `README.md`
- [x] `clipsterd/README.md` — architecture, components, data flow, schema
- [x] `clipster-client/README.md` — architecture, components, state machine, wire format

### Open Items
- Intel Mac performance validation — requires physical Intel hardware or GitHub CI macOS Intel runner; noted as manual QA item.
- Notarisation of release binaries — requires Developer ID certificate; documented in Makefile targets and `scripts/sign.sh`.

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
