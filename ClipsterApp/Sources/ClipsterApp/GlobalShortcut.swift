import AppKit
import Carbon

/// Global keyboard shortcut listener using CGEventTap.
/// Default shortcut: ⌘⇧V (configurable in Settings, §7.8).
/// Requires Accessibility permission (same permission as CGEvent paste).
final class GlobalShortcut {
    /// Shortcut definition: key + modifiers.
    struct Shortcut {
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags

        /// Default ⌘⇧V
        static let defaultPaste = Shortcut(
            keyCode: 9, // V
            modifiers: [.maskCommand, .maskShift]
        )
    }

    private var shortcut: Shortcut
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let action: () -> Void

    init(shortcut: Shortcut = .defaultPaste, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.action = action
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .keyDown,
                  let userInfo = userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let shortcutRef = Unmanaged<GlobalShortcut>.fromOpaque(userInfo).takeUnretainedValue()
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

            if keyCode == shortcutRef.shortcut.keyCode && flags == shortcutRef.shortcut.modifiers {
                DispatchQueue.main.async {
                    shortcutRef.action()
                }
                return nil // Consume the event
            }
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        )

        guard let tap = eventTap else {
            // Accessibility permission not granted — tap creation fails silently.
            // The app will degrade gracefully (menu bar click still works).
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    deinit { stop() }
}
