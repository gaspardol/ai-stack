import AppKit
import SwiftUI

/// AppKit-managed windows hosting SwiftUI content. The app shows a Dock icon only while one is open.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, size: CGSize, minSize: CGSize? = nil, content: () -> Content) {
        if let window = windows[id] {
            bringToFront(window)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        if let minSize { window.contentMinSize = minSize }
        window.delegate = self
        // Open on the Space the user is on, even over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.setFrameAutosaveName("AIStack.\(id)")
        windows[id] = window
        bringToFront(window)
    }

    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible ?? false }

    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        if windows.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
