import AppKit
import EventKit

struct MeetingAppInfo {
    let name: String
    let isBrowser: Bool
    /// Bundle ID prefix used to find the browser's main app for tab inspection.
    let prefix: String
}

enum MeetingApps {
    private static let native: [(String, String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Microsoft Teams"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"), ("com.apple.avconferenced", "FaceTime"), ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"), ("com.webex", "Webex"), ("com.hnc.Discord", "Discord"),
        ("net.whatsapp", "WhatsApp"), ("desktop.WhatsApp", "WhatsApp"), ("ru.keepcoder.Telegram", "Telegram"),
        ("com.tdesktop", "Telegram"), ("org.whispersystems.signal", "Signal"), ("com.skype", "Skype"),
        ("com.amazon.Amazon-Chime", "Chime"), ("com.ringcentral", "RingCentral"), ("com.gotomeeting", "GoTo Meeting"),
    ]
    private static let browsers: [(String, String)] = [
        ("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit", "Safari"),
        ("company.thebrowser", "Arc"), ("com.brave.Browser", "Brave"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"), ("com.vivaldi", "Vivaldi"), ("com.operasoftware", "Opera"),
        ("org.chromium", "Chromium"), ("app.zen-browser", "Zen"),
    ]

    static func classify(_ bundleID: String) -> MeetingAppInfo? {
        if let match = native.first(where: { bundleID.hasPrefix($0.0) }) {
            return MeetingAppInfo(name: match.1, isBrowser: false, prefix: match.0)
        }
        if let match = browsers.first(where: { bundleID.hasPrefix($0.0) }) {
            let prefix = match.0 == "com.apple.WebKit" ? "com.apple.Safari" : match.0
            return MeetingAppInfo(name: match.1, isBrowser: true, prefix: prefix)
        }
        return nil
    }
}

enum BrowserTabs {
    enum Result {
        case meeting(service: String, title: String?)
        case none
        /// Couldn't inspect tabs (no automation permission, unsupported browser).
        case unknown
    }

    private static let services: [(pattern: String, name: String)] = [
        (#"meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3}"#, "Google Meet"),
        (#"teams\.(microsoft|live)\.com"#, "Microsoft Teams"),
        (#"zoom\.us/(wc|j|s|my)/"#, "Zoom"), (#"app\.zoom\.us"#, "Zoom"),
        (#"whereby\.com/."#, "Whereby"), (#"\.webex\.com"#, "Webex"),
        (#"app\.slack\.com/huddle"#, "Slack Huddle"), (#"discord\.com/channels"#, "Discord"),
        (#"meet\.jit\.si/."#, "Jitsi"), (#"around\.co"#, "Around"), (#"riverside\.fm/studio"#, "Riverside"),
        (#"gather\.town/app"#, "Gather"), (#"app\.gather\.town"#, "Gather"), (#"facetime\.apple\.com/join"#, "FaceTime"),
        (#"streamyard\.com/."#, "StreamYard"), (#"app\.chime\.aws"#, "Chime"),
    ]

    /// Lists the tabs of a running browser via AppleScript. Call off the main thread.
    static func findMeeting(browserPrefix: String) -> Result {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.bundleIdentifier ?? "").hasPrefix(browserPrefix) && $0.activationPolicy == .regular
        }), let bundleID = app.bundleIdentifier else { return .unknown }

        let titleProperty = browserPrefix == "com.apple.Safari" ? "name" : "title"
        guard browserPrefix != "org.mozilla.firefox" else { return .unknown }
        let script = """
        set out to ""
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & tab & (\(titleProperty) of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        guard let output = Shell.run("/usr/bin/osascript", ["-e", script]), !output.isEmpty else { return .unknown }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let url = parts.first else { continue }
            for service in services where url.range(of: service.pattern, options: .regularExpression) != nil {
                return .meeting(service: service.name, title: cleanTitle(parts.count > 1 ? parts[1] : nil, service: service.name))
            }
        }
        return .none
    }

    private static func cleanTitle(_ raw: String?, service: String) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        for prefix in ["Meet - ", "Meet – ", "Meet — "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        for suffix in [" | Microsoft Teams", " - Zoom", " | Zoom"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        // Meet codes, generic titles and "(1)" notification counters are not useful as names.
        title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        if title.range(of: #"^[a-z]{3,4}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil { return nil }
        if ["Meet", "Google Meet", "Microsoft Teams", "Zoom", "Teams", "Meeting"].contains(title) { return nil }
        return title
    }
}

final class CalendarHelper {
    static let shared = CalendarHelper()
    private var store = EKEventStore()

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var isAuthorized: Bool { status == .fullAccess }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            if granted { store = EKEventStore() }
            return granted
        } catch {
            Log.error("Calendar access failed: \(error.localizedDescription)", "notes")
            return false
        }
    }

    /// The calendar event happening now, if any.
    func currentEvent() -> (title: String, attendees: [String])? {
        guard isAuthorized else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600), end: now.addingTimeInterval(3600), calendars: nil)
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.startDate <= now.addingTimeInterval(15 * 60) && $0.endDate >= now.addingTimeInterval(-10 * 60)
        }
        func score(_ event: EKEvent) -> Double {
            var value = -abs(event.startDate.timeIntervalSince(now)) / 60
            if (event.attendees?.count ?? 0) > 0 { value += 30 }
            let haystack = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
            if ["meet.google", "zoom.us", "teams.microsoft", "webex", "whereby"].contains(where: haystack.contains) { value += 60 }
            return value
        }
        guard let event = candidates.max(by: { score($0) < score($1) }) else { return nil }
        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            if let name = participant.name, !name.isEmpty { return name }
            return participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        return (event.title ?? "Meeting", attendees)
    }
}

/// Watches who uses the microphone. When a call app (or a browser with a meeting tab) starts
/// recording, it starts the meeting recorder; when the call app releases the mic, it stops it.
@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var activeCallApp: String?

    private let recorder: MeetingRecorder
    private var timer: Timer?
    private var micActiveSince: Date?
    private var micReleasedSince: Date?
    /// Set when the user stops (or declines) a recording while the call is still going.
    private var suppressUntilRelease = false
    private var checkingBrowser = false
    private var lastBrowserCheck = Date.distantPast
    private var lastUsers = ""
    private(set) var pending: (app: String, title: String?)?

    init(recorder: MeetingRecorder) {
        self.recorder = recorder
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func suppressCurrentCall() { suppressUntilRelease = true }

    func startPending() {
        let info = pending
        pending = nil
        recorder.start(app: info?.app, suggestedTitle: info?.title, automatic: true)
    }

    private func poll() {
        let ownPID = getpid()
        let users = CA.microphoneUsers().filter { $0.pid != ownPID }
        let signature = users.map(\.bundleID).sorted().joined(separator: ",")
        if signature != lastUsers {
            lastUsers = signature
            Log.info("Mic users: [\(signature)]", "detector")
        }
        let calls = users.compactMap { user in MeetingApps.classify(user.bundleID) }
        activeCallApp = calls.first?.name

        if recorder.isRecording {
            guard recorder.startedAutomatically else { return }
            if calls.isEmpty {
                if micReleasedSince == nil { micReleasedSince = Date() }
                if let since = micReleasedSince, Date().timeIntervalSince(since) > 20 {
                    Log.info("Call ended (mic released) — stopping", "detector")
                    micReleasedSince = nil
                    recorder.stop()
                }
            } else {
                micReleasedSince = nil
            }
            return
        }
        micReleasedSince = nil

        guard !calls.isEmpty else {
            micActiveSince = nil
            suppressUntilRelease = false
            pending = nil
            return
        }
        guard AppSettings.shared.notesEnabled, AppSettings.shared.notesMode != "manual", !suppressUntilRelease else { return }
        guard let since = micActiveSince else { micActiveSince = Date(); return }
        guard Date().timeIntervalSince(since) >= 3 else { return }

        if let app = calls.first(where: { !$0.isBrowser }) {
            trigger(app: app.name, title: nil)
            return
        }
        guard !checkingBrowser, Date().timeIntervalSince(lastBrowserCheck) > 8, let browser = calls.first else { return }
        checkingBrowser = true
        lastBrowserCheck = Date()
        Task.detached {
            let result = BrowserTabs.findMeeting(browserPrefix: browser.prefix)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checkingBrowser = false
                switch result {
                case .meeting(let service, let title): self.trigger(app: service, title: title)
                case .unknown: self.trigger(app: browser.name, title: nil)
                case .none: break // mic used by a website that isn't a known meeting service
                }
            }
        }
    }

    private func trigger(app: String, title: String?) {
        guard !recorder.isRecording, pending == nil else { return }
        Log.info("Call detected: \(app) \(title ?? "")", "detector")
        if AppSettings.shared.notesMode == "ask" {
            pending = (app, title)
            suppressUntilRelease = true
            Notifier.meetingDetected(app: app, title: title)
        } else {
            recorder.start(app: app, suggestedTitle: title, automatic: true)
        }
    }
}
