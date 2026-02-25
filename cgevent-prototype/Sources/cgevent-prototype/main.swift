import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// ─── CGEvent Paste Prototype ──────────────────────────────────────────────────
// Phase 5 Go/No-Go gate — v3 PRD §7.3 + §13 (Phase 0)
//
// PURPOSE: prove CGEvent ⌘V simulation works end-to-end with a notarised binary.
//
// USAGE:
//   1. Build + sign + notarise (see scripts/sign-prototype.sh)
//   2. Run: ./cgevent-prototype
//   3. When prompted, focus a target app (TextEdit, Terminal, Notes, etc.)
//   4. Observe whether the test string is pasted into that app.
//
// GATE PASS: notarised binary is accepted by Gatekeeper AND paste lands.
// GATE FAIL: CGEvent simulation is blocked post-notarisation → evaluate §7.3 fallbacks.

let version = "0.1.0-phase5-gate"

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(msg)")
    fflush(stdout)
}

// ─── Step 1: Accessibility check ─────────────────────────────────────────────

log("cgevent-prototype \(version) starting")
log("Checking Accessibility permission…")

let trusted = AXIsProcessTrusted()

if !trusted {
    log("⚠  Accessibility not granted.")
    log("   To grant permission:")
    log("   System Settings → Privacy & Security → Accessibility → add this binary")
    log("")
    // Prompt macOS to show the Accessibility dialog automatically on run
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    log("   A system permission dialog has been shown.")
    log("   Grant access, then re-run this binary.")
    exit(1)
}

log("✓ Accessibility granted")

// ─── Step 2: Write test payload to clipboard ──────────────────────────────────

let testPayload = "CLIPSTER_CGEVENT_GATE_\(Int(Date().timeIntervalSince1970))"
let pb = NSPasteboard.general
pb.clearContents()
pb.setString(testPayload, forType: .string)
log("✓ Clipboard set to: \(testPayload)")

// ─── Step 3: Countdown — user must focus a target app ─────────────────────────

let delay = 4
log("")
log("→ Focus your target app (TextEdit, Terminal, Notes, etc.) now.")
log("  Paste will be simulated in \(delay) seconds…")

for i in stride(from: delay, through: 1, by: -1) {
    log("  \(i)…")
    Thread.sleep(forTimeInterval: 1.0)
}

// ─── Step 4: CGEvent ⌘V simulation ────────────────────────────────────────────
//
// virtualKey 0x09 = kVK_ANSI_V
// We use .cghidEventTap which injects into the HID event stream at the hardware
// abstraction level — the same tap used by production assistive tools.

let source = CGEventSource(stateID: .hidSystemState)

guard
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
    let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
else {
    log("✗ Failed to create CGEvent — CGEvent API unavailable")
    exit(2)
}

keyDown.flags = .maskCommand
keyUp.flags   = .maskCommand

keyDown.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)   // brief gap between down and up
keyUp.post(tap: .cghidEventTap)

log("✓ CGEvent ⌘V posted")

// ─── Step 5: Verify clipboard content unchanged (not consumed) ────────────────
// Some apps consume the clipboard on paste; we verify the event posted cleanly
// by checking the clipboard is still intact (not an empty read).

Thread.sleep(forTimeInterval: 0.1)
let postPaste = NSPasteboard.general.string(forType: .string)
if postPaste == testPayload {
    log("✓ Clipboard content intact after paste event")
} else {
    log("⚠  Clipboard content changed after paste — may have been consumed by target app (expected)")
}

// ─── Result ───────────────────────────────────────────────────────────────────

log("")
log("═══════════════════════════════════════")
log("Phase 5 CGEvent Gate — Manual Verdict")
log("═══════════════════════════════════════")
log("Check the target app you focused.")
log("")
log("  PASS → The test string \"\(testPayload)\" was pasted into the target app.")
log("         Proceed to Phase 5.1 (Core GUI panel).")
log("")
log("  FAIL → No paste occurred, or paste was blocked after notarisation.")
log("         Evaluate fallback strategies per v3 PRD §7.3 before continuing.")
log("         Escalate to Alfred.")
log("")
