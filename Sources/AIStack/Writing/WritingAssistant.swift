import AppKit
import ApplicationServices
import Combine

/// System-wide writing assistant: watches the focused text field of the frontmost app through the
/// Accessibility API, checks it with Claude, and draws underlines + suggestion cards on top.
@MainActor
final class WritingAssistant: ObservableObject {
    enum Status: Equatable {
        case off, needsPermission, idle, checking, ready, failed(String)

        var description: String {
            switch self {
            case .off: return "Off"
            case .needsPermission: return "Needs Accessibility permission"
            case .idle: return "Waiting for text"
            case .checking: return "Checking…"
            case .ready: return "Active"
            case .failed(let message): return "Error: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    private(set) var lastExternalApp: NSRunningApplication?

    private let settings = AppSettings.shared
    private let engine = GrammarEngine()
    private let overlay = UnderlineOverlay()
    private let card = SuggestionCardController()
    private let badge = BadgeController()
    private let list = IssueListController()
    private var timer: Timer?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    // Focused element state
    private var element: AXUIElement?
    private var elementRole = ""
    private var clipAncestors: [AXUIElement] = []
    private var text = ""
    private var issues: [Issue] = []
    private var lastChange = Date.distantPast
    private var checking = false
    private var applying = false
    private var lastError: String?
    private var lastFrame: CGRect?
    private var lastAnchor: CGRect?
    private var geometryDirty = true
    private var rects: [String: [CGRect]] = [:]
    private var clipCocoa: CGRect = .null
    private var appElements: [pid_t: AXUIElement] = [:]
    private var loggedRoles = Set<String>()

    // Hover state
    private var hoverCandidate: String?
    private var hoverSince = Date()
    private var hoverOutSince: Date?

    private static let debounce: TimeInterval = 0.9
    private static let maxLength = 30_000

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleGlobalClick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.appElements[pid] = nil }
            }
        })
        ClaudeCLI.shared.prewarm(GrammarEngine.requestConfig(model: settings.writingModel))
    }

    // MARK: - Main loop

    private func tick() {
        guard settings.writingEnabled else { reset(); setStatus(.off); return }
        guard AX.isTrusted else { reset(); setStatus(.needsPermission); return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            reset(); return
        }
        lastExternalApp = app
        if let bundleID = app.bundleIdentifier, settings.disabledApps.contains(bundleID) { reset(); return }

        let appElement = axApp(for: app)
        guard let focused = appElement.focusedElement, let role = focused.role else { reset(); return }
        let subrole = focused.subrole
        logRoleOnce(app: app, role: role, subrole: subrole)
        guard Self.isEditable(role: role, subrole: subrole) else { reset(); return }

        if element == nil || !CFEqual(element!, focused) {
            reset()
            element = focused
            elementRole = role
            clipAncestors = Self.clipAncestors(of: focused)
            Log.info("Focused \(role)\(subrole.map { "/\($0)" } ?? "") in \(app.localizedName ?? "?")", "writing")
        }

        guard let value = focused.value, (value as NSString).length <= Self.maxLength else {
            clearMarks(); return
        }

        if value != text {
            let previous = text
            text = value
            lastChange = Date()
            let carried = Self.shift(issues, from: previous, to: value)
            recompute(provisional: carried)
            card.hide()
        }

        maybeCheck()
        updateGeometry()
        updateHover()
        updateBadge()
    }

    private func setStatus(_ new: Status) {
        if status != new { status = new }
    }

    private func reset() {
        guard element != nil || !issues.isEmpty || badge.isVisible else { return }
        element = nil
        elementRole = ""
        clipAncestors = []
        text = ""
        issues = []
        rects = [:]
        lastFrame = nil
        lastAnchor = nil
        geometryDirty = true
        overlay.update([])
        card.hide()
        badge.hide()
        list.hide()
    }

    private func clearMarks() {
        issues = []
        rects = [:]
        overlay.update([])
        card.hide()
        badge.hide()
    }

    private func axApp(for app: NSRunningApplication) -> AXUIElement {
        let pid = app.processIdentifier
        if let cached = appElements[pid] { return cached }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        // Electron & Chromium only build their accessibility tree when asked to.
        element.set("AXManualAccessibility", kCFBooleanTrue)
        if let bundleID = app.bundleIdentifier, Self.isChromiumBrowser(bundleID) {
            element.set("AXEnhancedUserInterface", kCFBooleanTrue)
        }
        appElements[pid] = element
        return element
    }

    private func logRoleOnce(app: NSRunningApplication, role: String, subrole: String?) {
        let key = "\(app.bundleIdentifier ?? "?")|\(role)|\(subrole ?? "")"
        guard loggedRoles.insert(key).inserted else { return }
        Log.info("Focus role in \(app.bundleIdentifier ?? "?"): \(role) \(subrole ?? "")", "writing")
    }

    static func isEditable(role: String, subrole: String?) -> Bool {
        if subrole == (kAXSecureTextFieldSubrole as String) || subrole == "AXSearchField" { return false }
        return role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String)
    }

    static func isChromiumBrowser(_ bundleID: String) -> Bool {
        ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser", "com.vivaldi.Vivaldi",
         "com.operasoftware.Opera", "org.chromium.Chromium"].contains { bundleID.hasPrefix($0) }
    }

    private static func usesWebTextStack(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if isChromiumBrowser(bundleID) { return true }
        return ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id", "com.microsoft.teams", "com.anthropic.claudefordesktop",
                "com.openai.chat", "net.whatsapp.WhatsApp", "com.linear", "md.obsidian"].contains { bundleID.hasPrefix($0) }
    }

    // MARK: - Issues

    /// Keeps underlines that the edit didn't touch, shifted to their new position.
    private static func shift(_ issues: [Issue], from old: String, to new: String) -> [Issue] {
        guard !issues.isEmpty else { return [] }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let editEndOld = a.count - suffix
        let delta = b.count - a.count
        return issues.compactMap { issue in
            if NSMaxRange(issue.range) < prefix { return issue }
            if issue.range.location > editEndOld { return issue.shifted(by: delta) }
            return nil
        }
    }

    private func recompute(provisional: [Issue]) {
        var result: [Issue] = []
        let string = text as NSString
        for paragraph in GrammarEngine.paragraphs(text) {
            if let cached = engine.cached(paragraph.text) {
                for item in cached {
                    let issue = Issue(paragraph: paragraph.text, offset: paragraph.range.location, item)
                    if engine.isIgnored(issue) { continue }
                    if issue.kind == .style && !settings.styleSuggestions { continue }
                    result.append(issue)
                }
            } else {
                result += provisional.filter {
                    $0.range.location >= paragraph.range.location && NSMaxRange($0.range) <= NSMaxRange(paragraph.range)
                }
            }
        }
        result = result.filter { NSMaxRange($0.range) <= string.length && string.substring(with: $0.range) == $0.text }
        if result.map(\.id) != issues.map(\.id) || result.map(\.range) != issues.map(\.range) {
            issues = result
            geometryDirty = true
        }
        refreshList()
    }

    private func maybeCheck() {
        guard !checking, !applying, Date().timeIntervalSince(lastChange) >= Self.debounce else { return }
        let caret = element?.selectedRange?.location ?? (text as NSString).length
        let batch = engine.paragraphsToCheck(in: text, caret: caret)
        guard !batch.isEmpty else {
            if status == .checking || status == .idle { setStatus(lastError == nil ? .ready : status) }
            return
        }
        checking = true
        setStatus(.checking)
        let appName = lastExternalApp?.localizedName ?? "an app"
        let model = settings.writingModel
        Task { [weak self] in
            let outcome: Result<[String: [ParagraphIssue]], Error>
            do {
                outcome = .success(try await GrammarEngine.check(batch, appName: appName, model: model))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            switch outcome {
            case .success(let results):
                self.engine.store(results)
                self.lastError = nil
                self.setStatus(.ready)
            case .failure(let error):
                self.engine.markFailed(batch)
                self.lastError = error.localizedDescription
                self.setStatus(.failed(error.localizedDescription))
                Log.error("Check failed: \(error.localizedDescription)", "writing")
            }
            self.checking = false
            self.recompute(provisional: self.issues)
        }
    }

    // MARK: - Geometry

    private static func clipAncestors(of element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var current = element.parent
        var depth = 0
        while let node = current, depth < 25 {
            let role = node.role
            if role == (kAXScrollAreaRole as String) || role == "AXWebArea" || role == (kAXWindowRole as String) {
                result.append(node)
            }
            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) { break }
            current = node.parent
            depth += 1
        }
        return result
    }

    private func updateGeometry() {
        guard let element, !issues.isEmpty else {
            if !rects.isEmpty || lastAnchor != nil {
                rects = [:]
                lastAnchor = nil
                overlay.update([])
            }
            updateClip()
            return
        }
        let frame = element.frame
        let anchor = element.bounds(for: NSRange(location: issues[0].range.location, length: 1))
        guard geometryDirty || frame != lastFrame || anchor != lastAnchor else { return }
        geometryDirty = false
        lastFrame = frame
        lastAnchor = anchor

        var clip = frame ?? .infinite
        for ancestor in clipAncestors {
            if let f = ancestor.frame { clip = clip.intersection(f) }
        }
        clipCocoa = clip.isNull ? .null : AX.toCocoa(clip)

        var newRects: [String: [CGRect]] = [:]
        for issue in issues {
            let lineRects = self.lineRects(element, issue.range).compactMap { rect -> CGRect? in
                let visible = rect.intersection(clip)
                guard !visible.isNull, visible.width >= 1, visible.height >= rect.height * 0.6 else { return nil }
                return AX.toCocoa(visible)
            }
            if !lineRects.isEmpty { newRects[issue.id] = lineRects }
        }
        rects = newRects
        redraw()
    }

    private func updateClip() {
        guard let element, let frame = element.frame else { clipCocoa = .null; return }
        var clip = frame
        for ancestor in clipAncestors {
            if let f = ancestor.frame { clip = clip.intersection(f) }
        }
        clipCocoa = clip.isNull ? .null : AX.toCocoa(clip)
    }

    private func lineRects(_ element: AXUIElement, _ range: NSRange) -> [CGRect] {
        guard range.length > 0, let whole = element.bounds(for: range), whole.height > 0, whole.height < 3000 else { return [] }
        if let first = element.bounds(for: NSRange(location: range.location, length: 1)), first.height > 0,
           whole.height <= first.height * 1.5 {
            return [whole]
        }
        // Spans several lines: measure word by word and merge per line.
        let string = text as NSString
        var lines: [CGRect] = []
        var index = range.location
        let end = min(NSMaxRange(range), string.length)
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 }
        while index < end {
            while index < end && isSpace(string.character(at: index)) { index += 1 }
            var wordEnd = index
            while wordEnd < end && !isSpace(string.character(at: wordEnd)) { wordEnd += 1 }
            if wordEnd > index, let rect = element.bounds(for: NSRange(location: index, length: wordEnd - index)), rect.height > 0 {
                if let last = lines.last, abs(last.midY - rect.midY) < last.height * 0.5 {
                    lines[lines.count - 1] = last.union(rect)
                } else {
                    lines.append(rect)
                }
            }
            index = wordEnd
        }
        return lines
    }

    private func redraw() {
        let highlighted = card.issue?.id
        var marks: [UnderlineMark] = []
        for issue in issues {
            for rect in rects[issue.id] ?? [] {
                marks.append(UnderlineMark(rect: rect, kind: issue.kind, highlighted: issue.id == highlighted))
            }
        }
        overlay.update(marks)
    }

    // MARK: - Hover & clicks

    private func issue(at point: CGPoint) -> (Issue, CGRect)? {
        for issue in issues {
            for rect in rects[issue.id] ?? [] where rect.insetBy(dx: -1, dy: -2).contains(point) {
                return (issue, rect)
            }
        }
        return nil
    }

    private func updateHover() {
        let point = NSEvent.mouseLocation
        if card.isVisible && card.frame.insetBy(dx: -8, dy: -8).contains(point) {
            hoverOutSince = nil
            return
        }
        if let (issue, rect) = issue(at: point) {
            hoverOutSince = nil
            if card.issue?.id == issue.id { return }
            if hoverCandidate != issue.id {
                hoverCandidate = issue.id
                hoverSince = Date()
            } else if Date().timeIntervalSince(hoverSince) > 0.22 {
                showCard(issue, anchor: rect, pinned: false)
            }
        } else {
            hoverCandidate = nil
            guard card.isVisible, !card.pinned else { return }
            if let since = hoverOutSince {
                if Date().timeIntervalSince(since) > 0.45 { hideCard() }
            } else {
                hoverOutSince = Date()
            }
        }
    }

    private func handleGlobalClick() {
        let point = NSEvent.mouseLocation
        if let (issue, rect) = issue(at: point) {
            showCard(issue, anchor: rect, pinned: true)
            return
        }
        if card.isVisible && !card.frame.contains(point) { hideCard() }
        if list.isVisible && !list.frame.contains(point) && !badge.frame.contains(point) { list.hide() }
    }

    private func showCard(_ issue: Issue, anchor: CGRect, pinned: Bool) {
        let appName = lastExternalApp?.localizedName ?? "this app"
        card.show(issue, anchor: anchor, appName: appName, pinned: pinned,
                  accept: { [weak self] in self?.accept(issue) },
                  ignore: { [weak self] in self?.ignore(issue) },
                  disableApp: { [weak self] in self?.disableCurrentApp() })
        redraw()
    }

    private func hideCard() {
        card.hide()
        hoverOutSince = nil
        redraw()
    }

    // MARK: - Badge & list

    private var badgeState: BadgeState {
        if checking { return .checking }
        if let lastError, issues.isEmpty { return .failed(lastError) }
        if issues.isEmpty { return .clean }
        return .issues(errors: issues.filter { $0.kind == .error }.count, style: issues.filter { $0.kind == .style }.count)
    }

    private func updateBadge() {
        guard element != nil, !clipCocoa.isNull, clipCocoa.height >= 34, clipCocoa.width >= 120,
              GrammarEngine.paragraphs(text).contains(where: { GrammarEngine.isCheckable($0.text) }) else {
            badge.hide()
            return
        }
        badge.show(badgeState, bottomRight: CGPoint(x: clipCocoa.maxX - 4, y: clipCocoa.minY + 4)) { [weak self] in
            self?.toggleList()
        }
    }

    private func listView() -> IssueListView {
        IssueListView(
            issues: issues,
            statusLine: checking ? "Checking with Claude…" : lastError.map { "Claude error: \($0)" },
            accept: { [weak self] issue in self?.accept(issue) },
            ignore: { [weak self] issue in self?.ignore(issue) },
            acceptAll: { [weak self] in self?.acceptAll() },
            acceptErrors: { [weak self] in self?.acceptAll(errorsOnly: true) },
            close: { [weak self] in self?.list.hide() }
        )
    }

    private func toggleList() {
        if list.isVisible { list.hide(); return }
        hideCard()
        list.show(listView(), anchor: badge.frame)
    }

    private func refreshList() {
        if list.isVisible { list.refresh(listView()) }
    }

    // MARK: - Actions

    func accept(_ issue: Issue) {
        hideCard()
        Task { _ = await apply(issue) }
    }

    func ignore(_ issue: Issue) {
        engine.ignore(issue)
        hideCard()
        recompute(provisional: issues)
    }

    func disableCurrentApp() {
        guard let bundleID = lastExternalApp?.bundleIdentifier else { return }
        if !settings.disabledApps.contains(bundleID) { settings.disabledApps.append(bundleID) }
        reset()
    }

    /// Accepts every visible suggestion (⌃⌥A), or only the corrections.
    func acceptAll(errorsOnly: Bool = false) {
        guard element != nil, !applying else { return }
        let targets = issues.filter { !errorsOnly || $0.kind == .error }.sorted { $0.range.location > $1.range.location }
        guard !targets.isEmpty else { NSSound.beep(); return }
        list.hide()
        hideCard()
        Task {
            // The shortcut fires on key-down: wait for ⌃/⌥ to be released so typed fixes aren't modified.
            for _ in 0..<40 where !NSEvent.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            var applied = 0
            // Later spans first, so earlier ranges stay valid while the text changes.
            for issue in targets {
                guard await apply(issue) else { break }
                applied += 1
            }
            Log.info("Accepted \(applied)/\(targets.count) suggestion(s)", "writing")
        }
    }

    /// Replaces the issue's span in the focused field. Returns true when the text was updated.
    private func apply(_ issue: Issue) async -> Bool {
        guard let element, let current = element.value else { return false }
        let string = current as NSString
        guard NSMaxRange(issue.range) <= string.length, string.substring(with: issue.range) == issue.text else {
            Log.error("Text changed under suggestion; not applying", "writing")
            return false
        }
        applying = true
        defer { applying = false }
        let expected = string.replacingCharacters(in: issue.range, with: issue.fix)
        engine.recordApplied(issue)

        guard element.setSelectedRange(issue.range) else {
            Log.error("Could not select text in \(lastExternalApp?.bundleIdentifier ?? "?")", "writing")
            return false
        }
        try? await Task.sleep(nanoseconds: 40_000_000)

        // Native text views apply AX writes synchronously; web/Electron views get synthetic typing.
        if !Self.usesWebTextStack(lastExternalApp?.bundleIdentifier) {
            if element.setSelectedText(issue.fix) == .success {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if element.value == expected { return true }
            }
        }
        guard element.selectedRange == issue.range, element.value == current else {
            let ok = element.value == expected
            if !ok { Log.error("Replacement could not be verified", "writing") }
            return ok
        }
        KeyboardTyper.replaceSelection(with: issue.fix)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if element.value == expected { return true }
        }
        Log.error("Typed replacement but text differs from expected", "writing")
        return false
    }
}
