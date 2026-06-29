import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum KeyboardFallback {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func sendDesktopShortcut(_ ordinal: Int) {
        guard let keyCode = keyCode(for: ordinal) else {
            NSSound.beep()
            return
        }

        pressControlChord(keyCode)
    }

    @discardableResult
    static func moveLeft(count: Int) -> TimeInterval {
        move(keyCode: 123, count: count)
    }

    @discardableResult
    static func moveRight(count: Int) -> TimeInterval {
        move(keyCode: 124, count: count)
    }

    private static func move(keyCode: CGKeyCode, count: Int) -> TimeInterval {
        guard count > 0 else {
            return 0.35
        }

        let interval = 0.68
        for step in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(step)) {
                pressControlChord(keyCode)
            }
        }
        return interval * Double(count) + 0.75
    }

    private static func pressControlChord(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let controlKey: CGKeyCode = 59

        let controlPreUp = CGEvent(keyboardEventSource: source, virtualKey: controlKey, keyDown: false)
        let controlDown = CGEvent(keyboardEventSource: source, virtualKey: controlKey, keyDown: true)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        let controlUp = CGEvent(keyboardEventSource: source, virtualKey: controlKey, keyDown: false)

        controlPreUp?.flags = []
        controlDown?.flags = [.maskControl]
        keyDown?.flags = [.maskControl]
        keyUp?.flags = [.maskControl]
        controlUp?.flags = []

        post(controlPreUp, after: 0)
        post(controlDown, after: 0.025)
        post(keyDown, after: 0.055)
        post(keyUp, after: 0.095)
        post(controlUp, after: 0.13)
    }

    private static func post(_ event: CGEvent?, after delay: TimeInterval) {
        guard let event else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            event.post(tap: .cghidEventTap)
        }
    }

    static func keyCode(for ordinal: Int) -> CGKeyCode? {
        switch ordinal {
        case 1: return 18
        case 2: return 19
        case 3: return 20
        case 4: return 21
        case 5: return 23
        case 6: return 22
        case 7: return 26
        case 8: return 28
        case 9: return 25
        default: return nil
        }
    }
}
