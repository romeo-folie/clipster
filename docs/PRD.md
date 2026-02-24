# PRD — Clipster CLI (Codename: Clipster CLI)

**Author:** Pam | **Date:** 2026-02-24 | **Status:** Draft v1 (CLI Phase) | **Owner:** Romeo Folie

---

> **Scope note:** This document covers the CLI-only implementation of Clipster. The menu bar GUI, SwiftUI floating panel, global keyboard shortcut, paste-to-previous-app via CGEvent, and all other graphical surfaces are explicitly deferred. See §14 (Deferred to GUI Phase). This PRD is the primary handoff to Devin for the first implementation sprint.

---

## 1. Overview

Clipster CLI is a macOS clipboard manager built for terminal-native workflows. It consists of two binaries:

- **`clipsterd`** — a headless Swift daemon that monitors NSPasteboard, classifies content, persists entries to SQLite, and exposes an IPC socket.
- **`clipster`** — a Go binary that provides a full terminal TUI and CLI commands, connecting to `clipsterd` via IPC. Falls back to read-only SQLite access when the daemon is not running.

There is no GUI, no menu bar icon, and no graphical surface of any kind in this phase. The user interacts exclusively through the terminal. Distribution is via a shell install script. Configuration is via a TOML file.

Free and open source.

---

## 2. Problem Statement

Existing macOS clipboard managers are built exclusively around graphical interfaces. Power users — especially developers — spend the majority of their working day in the terminal. No current clipboard manager provides a first-class terminal experience. The CLI gap is unaddressed.

Additionally, the current generation of clipboard managers lacks content-awareness, source tracking, and smart transforms accessible from the terminal. Clipster CLI addresses all of this while deferring graphical complexity to a later phase.

---

## 3. Goals

1. Ship a production-quality clipboard manager accessible entirely from the terminal
2. Provide a full TUI and CLI command surface via the `clipster` binary
3. Differentiate through content-awareness, source tracking, and smart paste transforms — all accessible without a GUI
4. Establish a stable daemon architecture (`clipsterd`) that the future GUI phase can build on without architectural changes
5. Distribute via a simple shell install script — no DMG, no Homebrew cask, no App Store
6. Free and open source

---

## 4. Non-Goals (CLI Phase)

- Menu bar GUI or any graphical surface
- Global keyboard shortcut (⌘⇧V)
- Paste-to-previous-app via CGEvent
- Sparkle auto-update
- DMG installer
- Homebrew cask
- App Store distribution
- GUI settings panel
- iOS / iPadOS
- iCloud sync or any remote sync
- Team / shared clipboard
- Browser extension
- Pro / paid tier
- Multi-select in TUI (v2 consideration)
- Collections / labelled groups (v1.1)
- Code type correction UI
- Transform chaining
- Transform preview panel (GUI phase)

---

## 5. Users

- **Primary:** Developer / power user on macOS who lives in the terminal
- **Secondary:** General macOS power users comfortable with CLI tooling

---

## 6. Core Concepts

| Concept | Definition |
|---|---|
| **Entry** | A single clipboard snapshot: content + metadata (type, source app, timestamp, source_confidence) |
| **History** | The ordered list of all entries, subject to count cap and DB size cap |
| **Pin** | An entry promoted to a persistent pinned section, unaffected by history pruning |
| **Collections** | Labelled groups of entries — v1.1, not in scope |
| **Transform** | An ephemeral, non-destructive operation applied to an entry's content at paste time |
| **`clipsterd`** | The headless Swift daemon that owns clipboard monitoring and all database writes |
| **`clipster`** | The Go CLI/TUI binary that connects to `clipsterd` via IPC or falls back to read-only SQLite |
| **Fallback mode** | State entered by `clipster` when `clipsterd` is not running — read-only, no writes |

---

## 7. Functional Requirements

### 7.1 Clipboard Monitoring

> **Owner:** `clipsterd` exclusively. The Go `clipster` binary never polls NSPasteboard.

**Polling:** NSPasteboard is polled every **250ms**.

**Debounce:** After a change is detected, a **50ms debounce window** is applied before the entry is written. If the pasteboard changes again within that 50ms window, the timer resets. Only the final state is captured; intermediate values are discarded. This prevents partial writes during rapid programmatic paste sequences.

**Detected content types:**

| Type | Detection method |
|---|---|
| `plain-text` | `public.utf8-plain-text` UTI |
| `rich-text` | `public.rtf` or `public.html` UTI |
| `image` | `public.image` UTI family |
| `url` | Valid URL structure (http/https/ftp scheme) within plain text |
| `file` | `public.file-url` UTI |
| `code` | Heuristic — see §7.1.1 |
| `colour` | Hex `#RRGGBB`/`#RRGGBBAA`, `rgb()`, `hsl()` — full-value match only |
| `email` | RFC 5322 address pattern |
| `phone` | E.164 or common regional formats |

**7.1.1 Code Snippet Detection (Heuristic)**

Code detection is **best-effort** and heuristic-based. It is not a parser. False positives are expected and accepted.

Detection applies a set of regex patterns to plain-text content:

- Presence of language keywords (`function`, `def`, `class`, `import`, `return`, `const`, `let`, `var`, `fn`, `pub`, `if`, `else`, `for`, `while`, etc.)
- Bracket density: high ratio of `{}`, `[]`, `()`, `<>` characters
- Indentation patterns: 2- or 4-space or tab-consistent indentation across ≥3 lines
- Common shebang lines (`#!/usr/bin/`, `#!/usr/local/bin/`)
- Operator patterns (`=>`, `->`, `::`, `===`, `!==`, `&&`, `||`)

A plain-text entry is classified as `code` if it matches **two or more** of the above signals.

**Tolerance:** Classification is advisory. Users see the `code` icon in the TUI as a visual hint. It has no functional consequence beyond display. No mechanism is provided to correct a misclassification in v1 (v2 consideration).

**Source App Attribution:**

Source app is captured via `NSWorkspace.shared.frontmostApplication` at the moment the change is detected (post-debounce timer expiry). This is **best-effort**:

- Attribution is correct in the vast majority of normal use cases.
- Rapid application focus switches between copy and detection may produce incorrect attribution. This is a **known limitation, not a bug**, and is documented.

The entry schema includes a `source_confidence` field:
- `"high"` — frontmost app has not changed during the debounce window
- `"low"` — frontmost app changed at least once during the debounce window

**Deduplication:** If the new entry's content hash matches the most recent entry in history, the copy is discarded (no duplicate created, timestamp not updated).

**Password Manager Suppression:** Any app whose bundle ID matches the configurable `suppress_bundles` list in `~/.config/clipster/config.toml` (defaults: 1Password, Bitwarden, Dashlane, LastPass) does not have its clipboard activity recorded. Content from suppressed apps is silently dropped — no placeholder entry is created.

---

### 7.2 Storage

> **Owner:** `clipsterd` exclusively. The Go CLI never writes to the SQLite database, even in fallback mode.

**Engine:** SQLite via GRDB (Swift).

**DB path:** `~/Library/Application Support/Clipster/history.db`

**Performance configuration:**
- WAL (Write-Ahead Logging) mode is **enabled at DB initialisation** (`PRAGMA journal_mode=WAL`).
- On daemon startup, if DB file size > 80% of the configured size cap, a `VACUUM` is triggered automatically.

**Schema:**

```sql
CREATE TABLE entries (
  id             TEXT PRIMARY KEY,         -- UUID
  content_type   TEXT NOT NULL,            -- plain-text | rich-text | image | url | file | code | colour | email | phone
  content        BLOB NOT NULL,
  preview        TEXT,                     -- truncated string for display
  source_bundle  TEXT,                     -- e.g. com.apple.Safari
  source_name    TEXT,
  source_confidence TEXT NOT NULL DEFAULT 'high', -- "high" | "low"
  created_at     INTEGER NOT NULL,         -- Unix timestamp ms
  is_pinned      INTEGER NOT NULL DEFAULT 0,
  content_hash   TEXT NOT NULL             -- SHA-256 of raw content
);

CREATE TABLE thumbnails (
  entry_id  TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
  data      BLOB NOT NULL                 -- JPEG, max 400px wide, 2MB
);
```

**History limits (count cap):** Configured via `[history] entry_limit` in `config.toml`.

| Label | Entry limit |
|---|---|
| Compact | 100 |
| Standard (default) | 500 |
| Extended | 1,000 |
| **No entry count limit** | No count limit — DB size cap still applies |

> ⚠️ The label "Unlimited" is **not used** anywhere in the product. The correct label is "No entry count limit". Users must understand that the DB size cap always applies regardless of this setting.

**DB size cap:** Default 500MB, configurable via `[history] db_size_cap_mb` in `config.toml` (100MB / 250MB / 500MB / 1GB). When the cap is reached, oldest non-pinned entries are pruned to bring size below 90% of cap.

**Images:** Max 2MB raw. Stored as JPEG thumbnail at max 400px width.

**Migrations:** Versioned migration system (GRDB migrations). Each migration is numbered and idempotent.

---

### 7.3 Daemon — `clipsterd`

`clipsterd` is a minimal headless Swift binary. It has no UI, no menu bar icon, no Dock presence. It runs as a macOS LaunchAgent.

#### 7.3.1 Binary Location

```
/usr/local/bin/clipsterd
```

#### 7.3.2 LaunchAgent Plist

**Location:** `~/Library/LaunchAgents/com.clipster.daemon.plist`

**Contents:**

```xml
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
        <string>/Users/REPLACE_WITH_USERNAME</string>
    </dict>
</dict>
</plist>
```

> The `HOME` environment variable is set by the install script at install time, substituting the actual username. This ensures `clipsterd` can resolve `~/Library/Application Support/Clipster/` and `~/.config/clipster/config.toml` correctly when launched by launchd (which does not set `HOME` automatically for user agents in all macOS versions).

#### 7.3.3 Socket Path

```
~/Library/Application Support/Clipster/clipster.sock
```

The socket is created by `clipsterd` on startup and removed on clean shutdown. The Go `clipster` binary connects to this path.

#### 7.3.4 Restart Policy

`KeepAlive: true` — launchd restarts `clipsterd` automatically if it exits for any reason (crash, signal, etc.). Intentional stops must go through `launchctl bootout` (see `clipster daemon stop`).

#### 7.3.5 Log Path

```
/tmp/clipsterd.log
```

Both stdout and stderr are directed here. The log level is controlled by `[daemon] log_level` in `config.toml`. On startup, `clipsterd` logs:
- Its version and PID
- Config file path loaded
- DB path
- Socket path
- Any config warnings or errors

#### 7.3.6 Startup Sequence

1. Read `~/.config/clipster/config.toml` (create defaults if missing)
2. Open / migrate SQLite DB at `~/Library/Application Support/Clipster/history.db`
3. Run VACUUM if DB size > 80% of cap
4. Bind Unix socket at `~/Library/Application Support/Clipster/clipster.sock`
5. Begin NSPasteboard polling loop (250ms interval)
6. Accept IPC connections from `clipster`

#### 7.3.7 Shutdown Sequence

On SIGTERM (sent by launchd or `clipster daemon stop`):

1. Stop accepting new IPC connections
2. Finish any in-flight DB write
3. Remove socket file
4. Close DB connection cleanly

---

### 7.4 Configuration — TOML Config File

**Path:** `~/.config/clipster/config.toml`

**Created by:** `clipsterd` on first startup if not present, with the default values shown below.

**Read by:** `clipsterd` at startup only. Config changes require a daemon restart to take effect (`clipster daemon restart`).

**Default config:**

```toml
[history]
entry_limit = 500          # 100 | 500 | 1000 | 0 (no limit)
db_size_cap_mb = 500       # max DB size in MB

[privacy]
suppress_bundles = [
  "com.1password.1password",
  "com.bitwarden.desktop",
  "com.dashlane.dashlane",
  "com.lastpass.LastPass"
]

[daemon]
log_level = "info"         # debug | info | warn | error
```

**Field reference:**

| Field | Type | Default | Valid values |
|---|---|---|---|
| `history.entry_limit` | integer | `500` | `100`, `500`, `1000`, `0` (no count limit) |
| `history.db_size_cap_mb` | integer | `500` | `100`, `250`, `500`, `1000` |
| `privacy.suppress_bundles` | array of strings | (see above) | Any bundle ID strings |
| `daemon.log_level` | string | `"info"` | `"debug"`, `"info"`, `"warn"`, `"error"` |

**Validation:** `clipsterd` validates the config at startup. If a field has an invalid value, `clipsterd` logs a warning, uses the default for that field, and continues (it does not exit on invalid config). This prevents a bad config edit from taking the daemon down permanently.

---

### 7.5 CLI / TUI

**Runtime:** Go 1.22+

**Libraries:** Bubble Tea (TUI), Lip Gloss (styling)

**Install location:** `~/.local/bin/clipster` (default) or `/usr/local/bin/clipster` (fallback if `~/.local/bin` is not writable)

**Commands:**

| Command | Description |
|---|---|
| `clipster` | Launch interactive TUI |
| `clipster pins` | List pinned entries |
| `clipster clear` | Clear history (prompts for confirmation) |
| `clipster last` | Print most recent entry to stdout |
| `clipster config` | Open `~/.config/clipster/config.toml` in `$EDITOR` (falls back to `vi` if `$EDITOR` is unset) |
| `clipster daemon status` | Show daemon status (running / not running, PID, uptime) |
| `clipster daemon start` | Start the daemon via `launchctl bootstrap` |
| `clipster daemon stop` | Stop the daemon via `launchctl bootout` |
| `clipster daemon restart` | Stop then start the daemon |

**TUI features:**
- Inline filtering (type to filter entries by content or source app)
- Entry type icons (text/unicode equivalents; Nerd Font icons if detected via `$TERM_PROGRAM` or `$NERD_FONTS` env var; fallback to plain Unicode)
- Source app name displayed on each entry row
- `source_confidence` displayed as a faded indicator on `"low"` confidence entries
- Select entry → copies content to system clipboard (user pastes manually with ⌘V)
- Tab on selected entry → opens inline transform selector (see §7.7)
- `p` on selected entry → pin / unpin

**TUI keybindings:**

| Key | Action |
|---|---|
| `↑` / `↓` or `j` / `k` | Navigate entries |
| Type any character | Begin inline filter |
| `Enter` | Copy selected entry to system clipboard |
| `Tab` | Open transform selector for selected entry |
| `p` | Pin / unpin selected entry |
| `d` | Delete selected entry (with confirmation prompt) |
| `Escape` | Clear filter / close transform selector / quit |
| `q` | Quit TUI |
| `?` | Show help overlay |

**Paste behaviour:** In this CLI phase, `clipster` does **not** use CGEvent to paste into other applications. When the user selects an entry (Enter), the content is written to the system clipboard. The user pastes manually with ⌘V. This is a deliberate scope decision — CGEvent paste is deferred to the GUI phase.

**Fallback mode (daemon not running):**

- `clipster` operates read-only against the SQLite database at `~/Library/Application Support/Clipster/history.db`
- No writes are made to the database in fallback mode — `clipsterd` is the sole write owner
- `clipster clear`, write-requiring IPC commands, and transform operations that require daemon confirmation are disabled with a clear explanatory message: `"clipsterd not running — this operation requires the daemon"`
- A persistent banner is displayed at the top of the TUI and in CLI output:

  ```
  ⚠  clipsterd not running — read-only mode. Run: clipster daemon start
  ```

---

### 7.6 IPC

**Transport:** Unix domain socket at `~/Library/Application Support/Clipster/clipster.sock`

**Framing:** 4-byte big-endian length prefix + UTF-8 JSON body

**Command envelope:**

```json
{
  "version": 1,
  "id": "<uuid-v4>",
  "command": "<command>",
  "params": { ... }
}
```

**Response envelope:**

```json
{
  "protocol_version": 1,
  "id": "<matching-uuid>",
  "ok": true,
  "data": { ... },
  "error": null
}
```

> The `version` / `protocol_version` field is **required** in all messages from v1 onwards. Clients that send an unrecognised version number receive an error response with `"error": "unsupported_protocol_version"` and the connection is closed gracefully. This provides a forward-compatible upgrade path.

**Commands:**

| Command | Direction | Requires daemon running |
|---|---|---|
| `list` | CLI → Daemon | No (fallback: read SQLite) |
| `pins` | CLI → Daemon | No (fallback: read SQLite) |
| `pin` | CLI → Daemon | **Yes** (write — no fallback) |
| `unpin` | CLI → Daemon | **Yes** (write — no fallback) |
| `delete` | CLI → Daemon | **Yes** (write — no fallback) |
| `last` | CLI → Daemon | No (fallback: read SQLite) |
| `transform` | CLI → Daemon | **Yes** (no fallback) |
| `clear` | CLI → Daemon | **Yes** (write — no fallback) |
| `daemon_status` | CLI → Daemon | No (resolved locally via socket check) |

**Write ownership:** `clipsterd` is the **sole owner of all database writes**. The Go CLI never writes to the SQLite database directly, even when it can read the file. This is an architectural invariant — not a recommendation.

**Socket reconnect:** The CLI socket layer uses a single-attempt connect with a 500ms timeout. On connect failure, it falls back to read-only SQLite mode immediately. There is no reconnect loop. This prevents any conflict during daemon restart — the daemon always starts fresh with a new socket and owns the connection state.

---

### 7.7 Transforms

> In this CLI phase, transforms are applied in-process by `clipster` (with the daemon confirming the operation via IPC). The result is written to the system clipboard. There is no CGEvent paste — the user applies the transformed content manually with ⌘V.

All transforms are **ephemeral** — they do not modify the stored entry.

| Transform | Input requirement | Error condition |
|---|---|---|
| Paste as plain text | Rich text | — |
| UPPERCASE | Any text | — |
| lowercase | Any text | — |
| Title Case | Any text | — |
| Trim whitespace | Any text | — |
| JSON Pretty | Valid JSON string | "Invalid JSON — cannot pretty-print" |
| JSON Minify | Valid JSON string | "Invalid JSON — cannot minify" |
| URL Encode | Any text | — |
| URL Decode | Percent-encoded string | "URL decode failed — malformed percent-encoding" |
| Base64 Encode | Any text | — |
| Base64 Decode | Valid Base64 string | "Not valid Base64 — cannot decode" |

**Transform errors:** If a transform fails (e.g. JSON Pretty on non-JSON input), the error message is displayed:
- In TUI: as a persistent status bar message at the bottom of the terminal — not auto-dismissed
- In non-interactive mode: printed to stderr
- The transform is not applied; the original entry remains on the clipboard unchanged
- The user must press Escape or `q` to dismiss in TUI

**Transform invariant:** Transforms always operate on the original stored content. There is no mechanism to chain transforms in v1.

**TUI transform selector:**

When Tab is pressed on a selected entry, the TUI replaces the entry list with a transform selector (full-height inline, no separate panel):

```
  Transforms — [entry preview]
  ─────────────────────────────
  > Paste as plain text
    UPPERCASE
    lowercase
    Title Case
    Trim whitespace
    JSON Pretty
    JSON Minify
    URL Encode
    URL Decode
    Base64 Encode
    Base64 Decode

  Enter: apply & copy to clipboard   Escape: cancel
```

Enter applies the selected transform, writes the result to the system clipboard, and returns to the entry list. Escape cancels with no change.

---

### 7.8 Distribution — Install Script

**No DMG. No Homebrew cask. No Sparkle. No App Store.**

Distribution for v1 is via two shell scripts hosted alongside the GitHub Release.

#### 7.8.1 `install.sh`

**Source:** Hosted at `https://github.com/[org]/clipster/releases/latest/download/install.sh`

**Behaviour:**

1. Detect macOS version (minimum: macOS 13 Ventura). Exit with a clear error if below minimum.
2. Detect architecture (arm64 / x86_64) and download the appropriate binary pair from GitHub Releases:
   - `clipsterd-darwin-{arch}` → `/usr/local/bin/clipsterd`
   - `clipster-darwin-{arch}` → `~/.local/bin/clipster` (create `~/.local/bin/` if needed; fallback to `/usr/local/bin/clipster` if not writable)
3. `chmod +x` both binaries.
4. Write the LaunchAgent plist to `~/Library/LaunchAgents/com.clipster.daemon.plist`, substituting the actual `$HOME` and username into the plist's `EnvironmentVariables` block.
5. Load the LaunchAgent:
   ```sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.clipster.daemon.plist
   ```
6. Verify the daemon started by checking for the socket at `~/Library/Application Support/Clipster/clipster.sock` (retry up to 5 times, 1s apart).
7. If `~/.local/bin` is not in `$PATH`, print a reminder:
   ```
   ℹ  Add ~/.local/bin to your PATH:
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
      source ~/.zshrc
   ```
8. Print a success message:
   ```
   ✓ Clipster installed successfully.
     daemon: clipsterd running (PID XXXXX)
     cli:    clipster at ~/.local/bin/clipster
     Run 'clipster' to open the TUI.
   ```

**Error handling:** Any step failure prints a clear error message and exits non-zero. The script does not partially install — if download fails, no plist is written. If plist install fails, binaries are not left behind without cleanup.

#### 7.8.2 `uninstall.sh`

**Behaviour:**

1. Unload the LaunchAgent:
   ```sh
   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.clipster.daemon.plist
   ```
   (Gracefully handles the case where it is not loaded.)
2. Remove the plist: `rm -f ~/Library/LaunchAgents/com.clipster.daemon.plist`
3. Remove the daemon binary: `rm -f /usr/local/bin/clipsterd`
4. Remove the CLI binary: `rm -f ~/.local/bin/clipster` and `rm -f /usr/local/bin/clipster` (whichever exists)
5. **Do not remove** `~/Library/Application Support/Clipster/history.db` or `~/.config/clipster/config.toml` by default — user data is preserved unless `--purge` flag is passed.
6. If `--purge` is passed: also remove `~/Library/Application Support/Clipster/` and `~/.config/clipster/`.
7. Print a summary of what was removed and a reminder about user data if not purged.

---

## 8. Architecture

```
┌─────────────────────────────────────────────────────────┐
│  macOS                                                   │
│                                                          │
│  ┌──────────────────────────────────┐                   │
│  │  clipsterd  (Swift, LaunchAgent) │                   │
│  │  - NSPasteboard polling (250ms)  │                   │
│  │  - Entry classification          │                   │
│  │  - SQLite writes (GRDB)          │                   │
│  │  - Unix socket IPC server        │                   │
│  └───────────────┬──────────────────┘                   │
│                  │ Unix socket                           │
│                  │ ~/Library/Application Support/        │
│                  │ Clipster/clipster.sock                │
│                  │                                       │
│  ┌───────────────▼──────────────────┐                   │
│  │  clipster  (Go, user binary)     │                   │
│  │  - TUI (Bubble Tea + Lip Gloss)  │                   │
│  │  - CLI commands                  │                   │
│  │  - Read-only SQLite fallback     │                   │
│  └──────────────────────────────────┘                   │
│                                                          │
│  Config:  ~/.config/clipster/config.toml                │
│  DB:      ~/Library/Application Support/Clipster/        │
│           history.db                                     │
│  Socket:  ~/Library/Application Support/Clipster/        │
│           clipster.sock                                  │
│  Log:     /tmp/clipsterd.log                            │
└─────────────────────────────────────────────────────────┘
```

**Daemon binary:** Swift (no UI frameworks, no AppKit/SwiftUI imports)
**Storage:** GRDB (SQLite wrapper for Swift)
**CLI/TUI:** Go 1.22+ + Bubble Tea + Lip Gloss
**IPC:** Unix domain socket (see §7.6)
**Config:** TOML, parsed by `clipsterd` at startup
**Distribution:** Shell install script
**Signing:** Developer ID signed. Notarisation required for Gatekeeper (both `clipsterd` and `clipster` must be notarised).

**Minimum macOS version:** 13 (Ventura) — requires engineering confirmation.

---

## 9. Privacy & Security

- All data stored locally. No network calls, no telemetry, no analytics.
- Password manager suppression by default (see §7.1 — configurable via `suppress_bundles` in config.toml).
- No cloud sync of any kind.
- Full source code is open source.
- `source_confidence` field in schema is informational only; no inference is made from it beyond display.
- The install script downloads binaries over HTTPS from GitHub Releases. Checksums (SHA-256) are printed after download and verified against a checksum file published alongside each release. The install script exits if verification fails.
- `clipsterd` runs with standard user-level permissions. No elevated privileges, no sudo, no kernel extensions.

---

## 10. Acceptance Criteria

### 10.1 Copy Capture

| ID | Criteria | Pass condition |
|---|---|---|
| AC-CAP-01 | Plain text copied in any app is captured within 350ms of the copy event | Entry appears in history within 350ms (250ms poll + 50ms debounce + processing margin) |
| AC-CAP-02 | Duplicate copy of the most recent entry is not stored | History count unchanged after duplicate copy |
| AC-CAP-03 | Content from a suppressed app is not stored | No entry created; no placeholder shown |
| AC-CAP-04 | Image is stored as JPEG thumbnail ≤ 2MB, ≤ 400px wide | File size and dimensions verified in DB |
| AC-CAP-05 | `source_confidence` is `"low"` when frontmost app changes during debounce window | Simulate rapid app switch; verify field value |
| AC-CAP-06 | Code snippet heuristic fires on a canonical Python/JS/Swift sample | Entry classified as `code` type |
| AC-CAP-07 | Rich text entry receives `rich-text` content_type in DB | DB `content_type` field verified |

### 10.2 Daemon Lifecycle

| ID | Criteria | Pass condition |
|---|---|---|
| AC-DAEMON-01 | `clipster daemon status` reports running with PID when daemon is active | Output contains "running" and a valid PID |
| AC-DAEMON-02 | `clipster daemon status` reports "not running" when daemon is stopped | Output contains "not running" |
| AC-DAEMON-03 | `clipster daemon stop` stops `clipsterd` and removes the socket file | `lsof` shows no clipsterd process; socket file absent |
| AC-DAEMON-04 | `clipster daemon start` starts `clipsterd` and socket is available within 5s | Socket file present within 5 seconds |
| AC-DAEMON-05 | `clipster daemon restart` stops and restarts the daemon | Daemon PID changes; history accessible after restart |
| AC-DAEMON-06 | `clipsterd` restarts automatically after a crash (KeepAlive) | Kill `clipsterd` with SIGKILL; verify it relaunches within 10s via launchd |
| AC-DAEMON-07 | Daemon writes its PID and version to log on startup | `/tmp/clipsterd.log` contains version and PID line |

### 10.3 IPC

| ID | Criteria | Pass condition |
|---|---|---|
| AC-IPC-01 | CLI with no running daemon enters read-only fallback mode with banner | Banner visible; write commands rejected |
| AC-IPC-02 | CLI in fallback mode does not write to the SQLite database | DB file mtime unchanged after fallback-mode list operation |
| AC-IPC-03 | IPC command envelope includes `"version": 1` | Inspect wire format via socket sniffer |
| AC-IPC-04 | IPC response envelope includes `"protocol_version": 1` | Inspect wire format |
| AC-IPC-05 | Sending `"version": 999` returns `"unsupported_protocol_version"` error | Verify error response and clean disconnect |

### 10.4 CLI / TUI

| ID | Criteria | Pass condition |
|---|---|---|
| AC-CLI-01 | `clipster` launches TUI within 300ms (Apple Silicon) | Measured from invocation to interactive |
| AC-CLI-02 | `clipster last` prints the most recent entry to stdout | stdout contains entry content |
| AC-CLI-03 | `clipster pins` lists all pinned entries | Output matches pinned entries in DB |
| AC-CLI-04 | `clipster clear` prompts for confirmation before clearing | Confirmation prompt visible; no action taken on 'n' |
| AC-CLI-05 | `clipster config` opens `~/.config/clipster/config.toml` in `$EDITOR` | Editor opens with config file |
| AC-CLI-06 | Inline TUI filter narrows entries in real-time as user types | Entry list updates with each keypress |
| AC-CLI-07 | Selecting an entry in TUI (Enter) writes it to the system clipboard | `pbpaste` confirms clipboard content matches entry |
| AC-CLI-08 | Pinning an entry in TUI (`p`) persists after TUI is closed and reopened | Entry has `is_pinned = 1` in DB; appears pinned in next TUI session |
| AC-CLI-09 | Deleting an entry in TUI (`d`) requires confirmation and removes from DB | Entry absent from DB after confirmed delete |
| AC-CLI-10 | Fallback mode banner is displayed at top of TUI when daemon not running | Banner visible in TUI header |

### 10.5 Transforms

| ID | Criteria | Pass condition |
|---|---|---|
| AC-XFORM-01 | Tab on a selected entry opens the inline transform selector | Transform list visible |
| AC-XFORM-02 | Enter applies the selected transform and copies result to system clipboard | `pbpaste` confirms transformed content |
| AC-XFORM-03 | Escape in transform selector returns to entry list with no transform applied | Entry list visible; `pbpaste` unchanged |
| AC-XFORM-04 | JSON Pretty on non-JSON input shows persistent error message "Invalid JSON — cannot pretty-print" | Error visible in TUI status bar; not auto-dismissed |
| AC-XFORM-05 | Base64 Decode on invalid input shows "Not valid Base64 — cannot decode" | Error visible; persists until Escape |
| AC-XFORM-06 | Transforms operate on original stored content, not a previously transformed value | Verify by applying transform, opening selector again, applying different transform — result matches original |

### 10.6 Performance

**Apple Silicon (M-series):**

| Metric | Target |
|---|---|
| `clipsterd` idle CPU | < 1% |
| `clipsterd` memory (resident) | < 50MB |
| `clipster` binary startup to interactive TUI | < 300ms |

**Intel Mac (baseline):**

| Metric | Target |
|---|---|
| `clipsterd` idle CPU | < 2% |
| `clipsterd` memory (resident) | < 80MB |
| `clipster` binary startup to interactive TUI | < 500ms |

All performance targets measured on a clean system (no other heavy processes) with history at default cap (500 entries).

### 10.7 Config File

| ID | Criteria | Pass condition |
|---|---|---|
| AC-CFG-01 | `~/.config/clipster/config.toml` is created with defaults on first daemon startup if not present | File exists with default values after fresh install |
| AC-CFG-02 | Changing `entry_limit` and restarting daemon (`clipster daemon restart`) applies the new limit | Old entries beyond new limit are pruned after restart |
| AC-CFG-03 | Adding a bundle ID to `suppress_bundles` and restarting daemon suppresses that app | Clipboard events from that app are not recorded after restart |
| AC-CFG-04 | Invalid `log_level` value falls back to `"info"` with a log warning | Daemon starts; log contains warning about invalid value |
| AC-CFG-05 | Config changes made while daemon is running have **no effect** until restart | Verify by changing limit, observing no immediate effect, then restarting |

### 10.8 Install / Uninstall

| ID | Criteria | Pass condition |
|---|---|---|
| AC-INST-01 | `install.sh` places `clipsterd` at `/usr/local/bin/clipsterd` | Binary present and executable |
| AC-INST-02 | `install.sh` places `clipster` at `~/.local/bin/clipster` (or `/usr/local/bin/clipster` fallback) | Binary present and executable |
| AC-INST-03 | `install.sh` writes plist to `~/Library/LaunchAgents/com.clipster.daemon.plist` | Plist file present with correct `HOME` substituted |
| AC-INST-04 | `install.sh` starts daemon and verifies socket is available within 5s | Socket present; success message printed |
| AC-INST-05 | `install.sh` prints PATH reminder if `~/.local/bin` is not in `$PATH` | Reminder message visible |
| AC-INST-06 | `install.sh` verifies SHA-256 checksum of downloaded binaries | Script exits non-zero if checksum mismatch |
| AC-INST-07 | `uninstall.sh` stops daemon, removes plist, removes binaries | No clipsterd process; no plist; no binaries |
| AC-INST-08 | `uninstall.sh` without `--purge` preserves `history.db` and `config.toml` | DB and config still present after uninstall |
| AC-INST-09 | `uninstall.sh --purge` removes all user data | `~/Library/Application Support/Clipster/` and `~/.config/clipster/` absent |
| AC-INST-10 | Running `install.sh` on macOS 12 or below exits with a clear error | Error message shown; no files installed |

---

## 11. Out of Scope (CLI Phase — Deferred)

See §14 (Deferred to GUI Phase) for the full list with rationale.

Additional items deferred from v1 overall:
- iOS / iPadOS
- iCloud sync or any remote sync
- Team / shared clipboard
- Browser extension
- App Store distribution
- Pro / paid tier
- Multi-select in TUI (v2 consideration)
- Collections / labelled groups (v1.1)
- Code type correction UI
- Transform chaining
- Nerd Font detection reliability improvements (v2)

---

## 12. Open Questions

| Question | Status | Notes |
|---|---|---|
| Minimum macOS version | **Open** | Proposal: macOS 13 (Ventura). Needs engineering confirmation. `launchctl bootstrap` semantics differ on older versions. |
| Nerd Font detection in TUI | **Open** | Check `$TERM_PROGRAM`, `$TERM`, or `$NERD_FONTS` env var. Fallback to Unicode always. |
| `source_confidence` display in TUI | **Open** | Show faded source name for `"low"` entries? Deferred to UX review. |
| Intel Mac performance testing | **Open** | Requires access to an Intel Mac in CI or manual QA. |
| Binary notarisation for `clipsterd` | **Open** | Notarisation is required for Gatekeeper. Both binaries must be signed with Developer ID. Confirm notarisation pipeline before Phase 1. |
| Config hot-reload vs restart | **Open** | Current spec: restart required. Could add SIGHUP-based hot-reload in a later release. Not in scope for v1. |

---

## 13. Implementation Phases

### Phase 0 — Prototype Gate (Week 1)

**Objective:** De-risk the daemon architecture before writing production code.

- [ ] Build a minimal `clipsterd` binary: NSPasteboard polling at 250ms, write one plain-text entry to SQLite on each change
- [ ] Verify the binary runs as a LaunchAgent (write plist, load via `launchctl bootstrap`, confirm autostart after logout/login)
- [ ] Confirm `clipsterd` survives a crash and is restarted by launchd (kill with SIGKILL, verify relaunch)
- [ ] Verify notarisation pipeline: sign and notarise the minimal binary with Developer ID; confirm Gatekeeper accepts it on a clean macOS install
- [ ] **Go / No-Go checkpoint:** If daemon runs correctly as a LaunchAgent and notarisation succeeds → proceed to Phase 1. If not → evaluate alternatives before continuing.

### Phase 1 — Core Daemon (Weeks 2–5)

- Full clipboard monitoring (all content types, debounce, source attribution, deduplication, password manager suppression)
- SQLite storage (WAL mode, schema, migrations, vacuum logic, all cap options)
- IPC socket server (versioned protocol, 4-byte framing, all commands, write ownership)
- Basic Go CLI: `list`, `last`, `pins`, fallback mode with banner
- `clipster daemon status|start|stop|restart`
- Config file parsing (TOML) — all fields, defaults, validation

### Phase 2 — Full CLI / TUI (Weeks 6–9)

- Bubble Tea TUI (inline filter, keybindings, type icons, source display, pin/unpin, delete)
- `clipster clear` with confirmation
- `clipster config` (open in $EDITOR)
- Full transform suite (all 11 transforms, error handling in TUI status bar and stderr)
- Fallback mode completeness (all write-blocked commands with clear error messages)
- `source_confidence` display in TUI

### Phase 3 — Install Script, Config Polish, Performance (Weeks 10–12)

- `install.sh` and `uninstall.sh` (full spec per §7.8)
- Checksum verification in install script
- Config file defaults creation on first run
- Full acceptance criteria test pass (all ACs in §10)
- Performance validation (Apple Silicon + Intel targets)
- Documentation: README, `clipster --help`, config file comments

---

## 14. Deferred to GUI Phase

The following features are explicitly deferred. They are **not in scope** for this CLI phase and should not be designed or implemented now. They are listed here to prevent scope creep and to give the GUI phase team a clear starting point.

### 14.1 Architectural Decision: How the GUI Phase Builds on This Work

**Decision (binding):** The GUI phase evolves `clipsterd` into the `.app` bundle. It does **not** replace `clipsterd` with a new binary.

Concretely:
- `clipsterd` is refactored to be both a background process **and** a menu bar application — the same binary, with AppKit/SwiftUI UI layer added on top.
- The Unix socket IPC contract remains unchanged. The existing `clipster` CLI binary continues to connect to the same socket with no modifications.
- The SQLite schema at `~/Library/Application Support/Clipster/clipster.db` is shared — no migration required at the CLI-to-GUI transition. Any new GUI-specific schema fields are added as backwards-compatible columns via the existing GRDB migration system.
- The LaunchAgent plist transitions from a background daemon to an app launch plist. The bundle ID `com.clipster.daemon` becomes the app's bundle ID.
- The TOML config at `~/.config/clipster/config.toml` is extended additively (new keys for shortcut, appearance, etc.). Existing CLI config keys remain valid and unchanged.

**Why this matters:** Devin must build `clipsterd` as a clean, evolvable foundation — not a throwaway daemon. Architectural shortcuts taken in the CLI phase (global state, tight coupling, hardcoded paths) will create rework at the GUI phase. Build it right the first time.

**What this means for Devin in the CLI phase:**
- The `clipsterd` binary should be a proper Swift package with clean separation between: clipboard monitoring, storage, IPC server, and (future) AppKit UI layer.
- Do not architect `clipsterd` in a way that assumes it will always be headless. Structure the code so a UI layer can be added without rewriting the core.
- The IPC protocol must be treated as a public contract from day one — not an internal implementation detail.

The GUI phase PRD will specify exactly how this transition is executed. No GUI work should begin without a formal GUI PRD that references this decision.

| Feature | Notes |
|---|---|
| Menu bar icon and status bar interface | Requires AppKit / SwiftUI |
| Floating panel (panel window above all apps) | Requires AppKit NSPanel |
| Global keyboard shortcut (⌘⇧V or configurable) | Requires KeyboardShortcuts package or CGEvent tap |
| Paste-to-previous-app via CGEvent | Requires Accessibility permission + notarisation proof-of-concept |
| GUI settings panel | Replaced in CLI phase by TOML config + `clipster config` |
| Transform preview panel (live hover preview) | GUI-only UX pattern |
| Entry type icons (graphical, non-Unicode) | GUI panel only; TUI uses Unicode fallback |
| GUI empty states (illustration + copy) | CLI phase uses plain text messaging |
| "Don't capture from [App Name]" context menu | CLI phase: user edits `suppress_bundles` in config.toml directly |
| Sparkle auto-update | Requires macOS app bundle |
| DMG installer | Requires signed .app |
| Homebrew cask | Deferred until post-GUI launch |
| Appearance setting (Auto / Light / Dark) | GUI-only |
| Rich text display in GUI (RTF badge) | GUI-only; TUI shows type label only |

---

## Appendix A — IPC Protocol Reference

### Command: `list`

Request:
```json
{ "version": 1, "id": "abc123", "command": "list", "params": { "limit": 50, "offset": 0 } }
```

Response:
```json
{ "protocol_version": 1, "id": "abc123", "ok": true, "data": { "entries": [ ... ] }, "error": null }
```

### Command: `pin`

Request:
```json
{ "version": 1, "id": "xyz789", "command": "pin", "params": { "entry_id": "<uuid>" } }
```

Response:
```json
{ "protocol_version": 1, "id": "xyz789", "ok": true, "data": {}, "error": null }
```

### Command: `clear`

Request:
```json
{ "version": 1, "id": "clr001", "command": "clear", "params": {} }
```

Response:
```json
{ "protocol_version": 1, "id": "clr001", "ok": true, "data": { "deleted_count": 342 }, "error": null }
```

### Command: `transform`

Request:
```json
{
  "version": 1,
  "id": "xfm001",
  "command": "transform",
  "params": {
    "entry_id": "<uuid>",
    "transform": "json_pretty"
  }
}
```

Response (success):
```json
{
  "protocol_version": 1,
  "id": "xfm001",
  "ok": true,
  "data": { "result": "{\n  \"key\": \"value\"\n}" },
  "error": null
}
```

Response (transform error):
```json
{
  "protocol_version": 1,
  "id": "xfm001",
  "ok": false,
  "data": null,
  "error": "Invalid JSON — cannot pretty-print"
}
```

### Error response (write command when daemon not running — returned by CLI locally, not via IPC):

```
clipsterd not running — this operation requires the daemon. Run: clipster daemon start
```

### Error response (unsupported protocol version):

```json
{ "protocol_version": 1, "id": "xyz789", "ok": false, "data": null, "error": "unsupported_protocol_version" }
```

---

## Appendix B — File System Layout

```
/usr/local/bin/clipsterd                                    ← daemon binary
~/.local/bin/clipster                                       ← CLI binary (or /usr/local/bin/clipster)
~/Library/LaunchAgents/com.clipster.daemon.plist            ← LaunchAgent definition
~/Library/Application Support/Clipster/history.db           ← SQLite database
~/Library/Application Support/Clipster/clipster.sock        ← IPC Unix socket (runtime only)
~/.config/clipster/config.toml                              ← user configuration
/tmp/clipsterd.log                                          ← daemon log (stdout + stderr)
```

---

## Appendix C — LaunchAgent Plist (Reference Copy)

```xml
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
        <string>/Users/REPLACED_BY_INSTALL_SCRIPT</string>
    </dict>
</dict>
</plist>
```

---

*End of PRD — Clipster CLI, Draft v1 (CLI Phase)*
