import AppKit
import SwiftUI

extension NSWindow.Level {
    static let aiStackOverlay = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue)
    static let aiStackPopover = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
}

extension IssueKind {
    var color: NSColor { self == .error ? NSColor(red: 0.90, green: 0.18, blue: 0.20, alpha: 1) : NSColor(red: 0.16, green: 0.45, blue: 0.95, alpha: 1) }
    var swiftUIColor: Color { Color(nsColor: color) }
    var label: String { self == .error ? "Correctness" : "Clarity" }
}

/// SwiftUI host that reacts to the first click even though its window never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, non-activating panel: clicking it never steals focus from the app being edited.
class FloatingPanel: NSPanel {
    init(level: NSWindow.Level, shadow: Bool = true) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func setContent<V: View>(_ view: V) {
        let host = FirstMouseHostingView(rootView: AnyView(view))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        setContentSize(size)
    }
}

// MARK: - Underlines

struct UnderlineMark {
    var rect: CGRect   // Cocoa screen coordinates
    var kind: IssueKind
    var highlighted: Bool
}

final class UnderlineOverlay {
    private let panel = FloatingPanel(level: .aiStackOverlay, shadow: false)
    private let view = UnderlineView()

    init() {
        panel.ignoresMouseEvents = true
        panel.collectionBehavior.insert(.stationary)
        panel.contentView = view
    }

    func update(_ marks: [UnderlineMark]) {
        guard !marks.isEmpty else {
            if panel.isVisible { panel.orderOut(nil) }
            view.marks = []
            return
        }
        let union = marks.reduce(CGRect.null) { $0.union($1.rect) }
        let screen = NSScreen.screens.first { $0.frame.intersects(union) } ?? NSScreen.main ?? NSScreen.screens[0]
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        view.marks = marks.map { mark in
            var local = mark
            local.rect = mark.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            return local
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

final class UnderlineView: NSView {
    var marks: [UnderlineMark] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            let color = mark.kind.color
            if mark.highlighted {
                color.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: mark.rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
            }
            let y = mark.rect.minY + 1
            let path = NSBezierPath()
            path.move(to: CGPoint(x: mark.rect.minX, y: y))
            path.line(to: CGPoint(x: mark.rect.maxX, y: y))
            path.lineWidth = 2
            path.lineCapStyle = .round
            color.withAlphaComponent(mark.highlighted ? 1 : 0.85).setStroke()
            path.stroke()
        }
    }
}

// MARK: - Suggestion card

struct SuggestionCardView: View {
    let issue: Issue
    let appName: String
    let accept: () -> Void
    let ignore: () -> Void
    let disableApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(issue.kind.swiftUIColor).frame(width: 8, height: 8)
                Text(issue.kind.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(issue.why.isEmpty ? "" : issue.why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            Button(action: accept) {
                VStack(alignment: .leading, spacing: 4) {
                    if issue.kind == .error || issue.text.count < 40 {
                        Text(issue.text)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(issue.fix.isEmpty ? "Remove" : issue.fix)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(issue.kind.swiftUIColor))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 14) {
                Button("Ignore", action: ignore)
                Button("Turn off in \(appName)", action: disableApp)
                Spacer()
                Image(systemName: "sparkle").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

final class SuggestionCardController {
    private let panel = FloatingPanel(level: .aiStackPopover)
    private(set) var issue: Issue?
    /// Opened by a click (stays until the next click) rather than by hovering.
    private(set) var pinned = false

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    func show(_ issue: Issue, anchor: CGRect, appName: String, pinned: Bool,
              accept: @escaping () -> Void, ignore: @escaping () -> Void, disableApp: @escaping () -> Void) {
        if self.issue?.id == issue.id && panel.isVisible {
            self.pinned = self.pinned || pinned
            return
        }
        self.issue = issue
        self.pinned = pinned
        panel.setContent(SuggestionCardView(issue: issue, appName: appName, accept: accept, ignore: ignore, disableApp: disableApp))
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin = CGPoint(x: anchor.minX - 12, y: anchor.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible || issue != nil else { return }
        panel.orderOut(nil)
        issue = nil
        pinned = false
    }
}

// MARK: - Badge + list of all suggestions

enum BadgeState: Equatable {
    case checking
    case clean
    case issues(errors: Int, style: Int)
    case failed(String)
}

struct BadgeView: View {
    let state: BadgeState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                switch state {
                case .checking:
                    ProgressView().controlSize(.mini).tint(.white)
                case .clean:
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                case .issues(let errors, let style):
                    Text("\(min(errors + style, 99))").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                case .failed:
                    Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .padding(3)
    }

    private var fill: Color {
        switch state {
        case .checking: return Color.gray.opacity(0.85)
        case .clean: return Color.green.opacity(0.9)
        case .issues(let errors, _): return errors > 0 ? IssueKind.error.swiftUIColor : IssueKind.style.swiftUIColor
        case .failed: return Color.orange
        }
    }

    private var help: String {
        switch state {
        case .checking: return "Checking with Claude…"
        case .clean: return "Looks good"
        case .issues(let e, let s): return "\(e) correction(s), \(s) clarity suggestion(s) — click to review"
        case .failed(let message): return "Claude error: \(message)"
        }
    }
}

final class BadgeController {
    private let panel = FloatingPanel(level: .aiStackPopover, shadow: false)
    private var state: BadgeState?
    private var origin: CGPoint?
    var frame: CGRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    func show(_ state: BadgeState, bottomRight: CGPoint, action: @escaping () -> Void) {
        if state != self.state {
            self.state = state
            panel.setContent(BadgeView(state: state, action: action))
        }
        let size = panel.frame.size
        let newOrigin = CGPoint(x: bottomRight.x - size.width, y: bottomRight.y)
        if newOrigin != origin {
            origin = newOrigin
            panel.setFrameOrigin(newOrigin)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        state = nil
        origin = nil
    }
}

struct IssueListView: View {
    let issues: [Issue]
    let statusLine: String?
    let accept: (Issue) -> Void
    let ignore: (Issue) -> Void
    let acceptAll: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(issues.isEmpty ? "No suggestions" : "\(issues.count) suggestion\(issues.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if issues.contains(where: { $0.kind == .error }) {
                    Button("Fix all errors", action: acceptAll)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(IssueKind.error.swiftUIColor)
                }
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            if let statusLine {
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(issues) { issue in
                        IssueRow(issue: issue, accept: { accept(issue) }, ignore: { ignore(issue) })
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct IssueRow: View {
    let issue: Issue
    let accept: () -> Void
    let ignore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(issue.kind.swiftUIColor).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.text).strikethrough().foregroundStyle(.secondary).lineLimit(2)
                Text(issue.fix.isEmpty ? "(remove)" : issue.fix).fontWeight(.medium).lineLimit(4)
                if !issue.why.isEmpty {
                    Text(issue.why).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                Button("Accept", action: accept).controlSize(.small)
                Button("Ignore", action: ignore).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

final class IssueListController {
    private let panel = FloatingPanel(level: .aiStackPopover)
    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }
    private var anchor: CGRect = .zero

    func show(_ view: IssueListView, anchor: CGRect) {
        self.anchor = anchor
        panel.setContent(view)
        position()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func refresh(_ view: IssueListView) {
        guard panel.isVisible else { return }
        panel.setContent(view)
        position()
    }

    private func position() {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin = CGPoint(x: anchor.maxX - size.width, y: anchor.maxY + 6)
        if origin.y + size.height > visible.maxY { origin.y = anchor.minY - size.height - 6 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = max(origin.y, visible.minY + 4)
        panel.setFrameOrigin(origin)
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) } }
}
