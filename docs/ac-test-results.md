# Clipster — Acceptance Criteria Test Results

**Date:** 2026-02-28
**Branch:** phase-3-distribution
**Platform:** Apple Silicon (arm64, macOS 15 Sequoia)
**Build:** debug (release build requires Developer ID signing)

---

## Legend

| Status | Meaning |
|--------|---------|
| ✅ PASS | Verified — criterion met |
| ❌ FAIL | Criterion not met — issue filed |
| ⚠️ PARTIAL | Partially verified; noted caveats |
| 🔲 MANUAL | Requires signed/notarised build or physical test — not automated |
| ⏭️ DEFERRED | Out of scope for current platform/hardware |

---

## §10.1 Copy Capture

| ID | Criterion | Status | Evidence / Notes |
|----|-----------|--------|-----------------|
| AC-CAP-01 | Plain text captured within 350ms of copy | 🔲 MANUAL | Requires daemon running. Poll interval 250ms + debounce 50ms = 300ms theoretical max; 50ms margin for SQLite write. Expected PASS. |
| AC-CAP-02 | Duplicate copy of most recent entry not stored | 🔲 MANUAL | Dedup logic in `ClipboardMonitor.swift` — content hash compared on every write. Code path verified by inspection; test with manual copy. |
| AC-CAP-03 | Content from suppressed app not stored | 🔲 MANUAL | Suppress set checked in `ClipboardMonitor` before write. GUI syncs list on launch via `AppDelegate.syncSuppressListToDaemon()`. Test: open 1Password, copy a password, verify no entry created. |
| AC-CAP-04 | Image stored as JPEG ≤ 2MB, ≤ 400px wide | 🔲 MANUAL | Image processing path in `ClipboardMonitor`. Test: copy a large image; verify `thumbnails` table row size and dimensions. |
| AC-CAP-05 | `source_confidence` = `"low"` when app changes during debounce | 🔲 MANUAL | Source tracking captures `frontmostApplication` after debounce expiry. Simulate with rapid app switch; inspect DB row. |
| AC-CAP-06 | Code heuristic fires on canonical Python/JS/Swift sample | 🔲 MANUAL | Code detection in `ContentClassifier.swift`. Test: copy a function body; verify `content_type = 'code'` in DB. |
| AC-CAP-07 | Rich text gets `rich-text` type + RTF badge in GUI | 🔲 MANUAL | Copy RTF from Pages or TextEdit; verify badge in panel. |

---

## §10.2 Paste to Previous App

| ID | Criterion | Status | Evidence / Notes |
|----|-----------|--------|-----------------|
| AC-PASTE-01 | Paste into previous app within 200ms of selection | 🔲 MANUAL | CGEvent timing. Requires Accessibility permission + notarised build. |
| AC-PASTE-02 | Paste works in: Terminal, Safari, VS Code, Notes, Mail | 🔲 MANUAL | Manual cross-app test matrix. Expected PASS on all five — CGEvent is app-agnostic. |
| AC-PASTE-03 | Degraded mode (no Accessibility): paste copies to clipboard + shows toast | 🔲 MANUAL | Revoke Accessibility permission in System Settings, try paste, verify toast. |
| AC-PASTE-04 | Rich text paste preserves formatting | 🔲 MANUAL | Paste RTF entry into Pages/Mail; verify formatting intact. |
| AC-PASTE-05 | "Paste as plain text" strips formatting | 🔲 MANUAL | Select entry → Tab → "Paste as plain text" → verify target receives plain text. |

---

## §10.3 Search Performance

| ID | Criterion | Status | Evidence / Notes |
|----|-----------|--------|-----------------|
| AC-SEARCH-01 | Results update within 100ms per keystroke (500 entries) | 🔲 MANUAL | Populate DB with 500 synthetic entries; measure keystroke→result latency. Search runs on background queue with debounce — expected PASS on Apple Silicon. |
| AC-SEARCH-02 | Results update within 300ms per keystroke (1,000 entries) | 🔲 MANUAL | As above with 1,000 entries. |
| AC-SEARCH-03 | Zero results shows "No matches for '[query]'" + "Clear search" | ✅ PASS | `ClipboardPanelView` empty-state implemented and verified during Phase 1 dev. |

---

## §10.4 Pin

| ID | Criterion | Status | Evidence / Notes |
|----|-----------|--------|-----------------|
| AC-PIN-01 | ⌘P pins entry; appears in Pinned section immediately | 🔲 MANUAL | IPC `pin` command → daemon writes → GUI refreshes. Test interactively. |
| AC-PIN-02 | Pinned entries survive pruning | 🔲 MANUAL | Add entries past count cap; verify pinned entry persists. `is_pinned=1` rows are excluded from pruning query (verified by inspection). |
| AC-PIN-03 | ⌘P on pinned entry unpins; returns to correct position | 🔲 MANUAL | Interactive test. `unpin` IPC → daemon moves row back. |
| AC-PIN-04 | Empty pins section shows instructional message | ✅ PASS | Empty-state copy present in `ClipboardPanelView` — verified during Phase 1. |

---

## §10.5 Transforms

| ID | Criterion | Status | Evidence / Notes |
|----|-----------|--------|-----------------|
| AC-XFORM-01 | Tab opens transform panel (bottom sheet) | ✅ PASS | `TransformPanelView` slide-up implemented and working. Verified during Phase 2 dev. |
| AC-XFORM-02 | Hover shows live preview within 100ms | ⚠️ PARTIAL | Preview fires on `onHover` — no debounce (tracked as MED in PR #42 review). Latency PASS expected; rapid hover over 11 items causes 11 sequential IPC calls (deferred fix). |
| AC-XFORM-03 | Enter applies transform and pastes | 🔲 MANUAL | Requires Accessibility permission. Paste target receives transformed content. |
| AC-XFORM-04 | Escape in transform panel returns to entry list, no transform | ✅ PASS | `onEscape` handler dismisses panel without applying. Verified by inspection + Phase 2 dev. |
| AC-XFORM-05 | JSON Pretty on non-JSON input shows persistent error toast | ✅ PASS | `TransformPanelView` error toast implemented: persists until Escape/click, includes specific failure message. |
| AC-XFORM-06 | Base64 Decode on invalid input shows persistent error toast | ✅ PASS | Same toast infrastructure as AC-XFORM-05. Verified during Phase 2. |
| AC-XFORM-07 | Transforms operate on original content, not previously transformed | ✅ PASS | `TransformPanelView` always passes `entry.content` to IPC — original, unmodified. |

---

## §10.6 Performance (Apple Silicon)

| Metric | Target | Measured | Status | Notes |
|--------|--------|----------|--------|-------|
| Idle CPU | < 1% | 🔲 MANUAL | 🔲 MANUAL | Measure via Activity Monitor with daemon + app running, no panel open, 5-min baseline. |
| Memory (resident) | < 80MB | 🔲 MANUAL | 🔲 MANUAL | Instruments → Allocations; check resident size at steady state. |
| `clipster` startup to interactive | < 300ms | **~31ms (warm)** | ✅ PASS | 5-run avg warm path: 31ms. Cold first-run: ~900ms (OS disk cache + 500ms socket timeout — expected on first execution; not representative of in-use latency). |
| Panel open latency | < 50ms | 🔲 MANUAL | 🔲 MANUAL | Measure from status bar click to popover-appeared using Instruments Timeline. |

### Intel Mac Performance

| Metric | Target | Status |
|--------|--------|--------|
| Idle CPU | < 2% | ⏭️ DEFERRED |
| Memory (resident) | < 120MB | ⏭️ DEFERRED |
| `clipster` startup | < 500ms | ⏭️ DEFERRED |
| Panel open latency | < 100ms | ⏭️ DEFERRED |

> No Intel Mac available in current dev environment. Targets are marked deferred; must be validated before public v1.0 release. Consider CI runner or community beta tester.

---

## §10.7 IPC / Fallback

| ID | Criterion | Status | Evidence / Notes |
|----|-----------|--------|-----------------|
| AC-IPC-01 | CLI with no running app enters read-only fallback with banner | ✅ PASS | `clipster-client/internal/ipc` fallback mode implemented. Banner displayed when socket connect fails. Verified in Phase 1 development. |
| AC-IPC-02 | Fallback mode does not write to SQLite | ✅ PASS | Write commands (`pin`, `unpin`, `delete`, `clear`) are rejected with `app_not_running` error in fallback. Reads go directly to SQLite in read-only mode. Verified by code inspection + Phase 1 tests. |
| AC-IPC-03 | IPC request envelope includes `"version": 1` | ✅ PASS | `IPCClient.swift` and `clipster-client` both set `version: 1` in all outgoing envelopes. Verified by inspection. |
| AC-IPC-04 | IPC response envelope includes `"protocol_version": 1` | ✅ PASS | `IPCServer.swift` sets `protocol_version: 1` on all responses. Verified by inspection. |
| AC-IPC-05 | `"version": 999` returns `"unsupported_protocol_version"` | ✅ PASS | Version check in `IPCServer.swift` handler. Verified by inspection + IPC contract test in Phase 1. |

---

## Open Issues / Deferred

| Issue | Severity | Tracking |
|-------|----------|---------|
| Transform hover IPC debounce missing — 11 calls on rapid hover | MED | Deferred from PR #42; fix before v1.0 |
| CLI install/uninstall blocks main thread (`waitUntilExit`) | MED | Deferred from PR #42; fix before v1.0 |
| Suppress list not re-synced if daemon restarts mid-session | LOW | Issue #43 |
| Intel Mac performance targets not yet validated | — | Needs Intel hardware or CI runner |
| `SUPublicEDKey` placeholder in Info.plist | BLOCKER for release | Run `generate_keys`, update Info.plist before signing |
| Sparkle `sign_update` step not yet in release workflow | BLOCKER for release | Must run before publishing appcast.xml + DMG |

---

## Release Checklist

Before tagging v0.1.0:

- [ ] Run `./dist/Sparkle/bin/generate_keys` → update `SUPublicEDKey` in `Info.plist`
- [ ] `make build-app` → `make sign-app` → `make notarise-app` → `make dmg`
- [ ] Run `./dist/Sparkle/bin/sign_update dist/Clipster-0.1.0.dmg` → update `docs/appcast.xml`
- [ ] `shasum -a 256 dist/Clipster-0.1.0.dmg` → update `Casks/clipster.rb sha256`
- [ ] Upload DMG + appcast.xml to GitHub Release `v0.1.0`
- [ ] Manual AC test pass: AC-CAP-01–07, AC-PASTE-01–05, AC-SEARCH-01–02, AC-PIN-01–03
- [ ] Idle CPU + memory measurement via Activity Monitor / Instruments (Apple Silicon)
- [ ] Panel open latency measurement
- [ ] Fix deferred MEDs: transform debounce + CLI main-thread block
