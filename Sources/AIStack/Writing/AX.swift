import AppKit
import ApplicationServices

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Accessibility uses top-left-origin global coordinates; AppKit uses bottom-left of the primary screen.
    static func toCocoa(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension AXUIElement {
    func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    func string(_ attribute: String) -> String? { copy(attribute) as? String }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = copy(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func axValue(_ attribute: String) -> AXValue? {
        guard let value = copy(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var value: String? { string(kAXValueAttribute) }
    var parent: AXUIElement? { element(kAXParentAttribute) }
    var focusedElement: AXUIElement? { element(kAXFocusedUIElementAttribute) }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }

    var selectedRange: NSRange? {
        guard let value = axValue(kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Frame in Accessibility (top-left origin) coordinates.
    var frame: CGRect? {
        if let value = axValue("AXFrame") {
            var rect = CGRect.zero
            if AXValueGetValue(value, .cgRect, &rect) { return rect }
        }
        guard let p = axValue(kAXPositionAttribute), let s = axValue(kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Screen bounds (Accessibility coordinates) of a UTF-16 character range.
    func bounds(for range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(self, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
              let value = out, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    @discardableResult
    func setSelectedRange(_ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(self, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func setSelectedText(_ text: String) -> AXError {
        AXUIElementSetAttributeValue(self, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }
}

/// Types text into the frontmost app through synthetic key events (fallback when AX writes are unsupported).
enum KeyboardTyper {
    static func replaceSelection(with text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        if text.isEmpty {
            post(keyCode: 51, source: source) // delete the selection
            return
        }
        for (index, character) in text.enumerated() {
            let units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.flags = []
            up.flags = []
            units.withUnsafeBufferPointer { pointer in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if index % 8 == 7 { usleep(2000) }
        }
    }

    private static func post(keyCode: CGKeyCode, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
