import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Headless checks: `AIStack --selftest grammar|transcribe <audio>|notes`
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), index + 1 < args.count else { return }
        let mode = args[index + 1]
        let extra = Array(args.dropFirst(index + 2))
        let done = DispatchSemaphore(value: 0)
        doneSignal = mode == "ax" ? done : nil
        Task.detached {
            do {
                switch mode {
                case "grammar": try await grammar(extra.first)
                case "transcribe": try await transcribe(extra.first ?? "", language: extra.dropFirst().first ?? "en-GB")
                case "notes": try await notes()
                case "ax": await MainActor.run { axTest() }; return
                default: print("unknown mode \(mode)")
                }
            } catch {
                print("FAILED: \(error.localizedDescription)")
            }
            done.signal()
        }
        if mode == "ax" {
            // AX + key events need the main run loop.
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        } else {
            done.wait()
        }
        exit(0)
    }

    private static func grammar(_ input: String?) async throws {
        let text = input ?? """
        Hi Mark,
        I wanted to reach out in order to to touch base regarding about the proposal that we was discussing last week. Their are a few points that I think needs more clarifications.
        Je pense que nous devrions organisé une réunion la semaine prochaine, si cela vous conviens.
        """
        ClaudeCLI.shared.prewarm(GrammarEngine.requestConfig(model: "haiku"))
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let engine = GrammarEngine()
        let batch = engine.paragraphsToCheck(in: text, caret: 0)
        let started = Date()
        let results = try await GrammarEngine.check(batch, appName: "Mail", model: "haiku")
        print(String(format: "latency %.2fs (warm)", Date().timeIntervalSince(started)))
        engine.store(results)
        for paragraph in GrammarEngine.paragraphs(text) {
            for item in engine.cached(paragraph.text) ?? [] {
                let issue = Issue(paragraph: paragraph.text, offset: paragraph.range.location, item)
                let actual = (text as NSString).substring(with: issue.range)
                print("[\(issue.kind.rawValue)] @\(issue.range.location) '\(actual)' → '\(issue.fix)'  (\(issue.why))  ok=\(actual == issue.text)")
            }
        }
        // Second request reuses the pre-started process.
        let second = Date()
        _ = try await GrammarEngine.check(["This are a test sentence."], appName: "Notes", model: "haiku")
        print(String(format: "second latency %.2fs", Date().timeIntervalSince(second)))
    }

    /// Streams an audio file through LiveTranscriber in real-time-ish chunks, like the mic would.
    private static func transcribe(_ path: String, language: String) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let transcriber = LiveTranscriber(speaker: .them)
        var segments: [Segment] = []
        let lock = NSLock()
        transcriber.onFinal = { segment in lock.lock(); segments.append(segment); lock.unlock(); print("final:", segment.text) }
        try await transcriber.start(languageID: language)
        let format = file.processingFormat
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else { break }
            try file.read(into: buffer, frameCount: 4800)
            if buffer.frameLength == 0 { break }
            transcriber.append(buffer)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await transcriber.finish()
        print("segments: \(segments.count)")
    }

    private static func notes() async throws {
        let start = Date().addingTimeInterval(-600)
        var meeting = Meeting(title: "Google Meet call", titleIsAuto: true, startedAt: start, endedAt: Date(), app: "Google Meet",
                              language: "en-GB", status: .processing)
        let lines: [(Speaker, String)] = [
            (.them, "Hi everyone, thanks for joining. Today we need to decide on the launch date for the new pricing page."),
            (.me, "Sure. I think we can be ready by the twenty fourth if design finishes the mockups this week."),
            (.them, "Sarah here. The final copy will be ready by Friday. Legal still needs to review the refund terms."),
            (.me, "Okay, I'll review the analytics dashboard next week and share conversion numbers with the team."),
            (.them, "Great. Let's tentatively say October twenty fourth, and Tom will confirm with legal by Wednesday."),
        ]
        for (index, line) in lines.enumerated() {
            let t = start.addingTimeInterval(Double(index) * 40)
            meeting.segments.append(Segment(speaker: line.0, start: t, end: t.addingTimeInterval(20), text: line.1))
        }
        meeting.userNotes = "launch date?\nlegal review"
        let started = Date()
        let markdown = try await NotesGenerator.generate(for: meeting)
        let (title, body) = NotesGenerator.split(markdown)
        print(String(format: "took %.1fs — title: %@\n", Date().timeIntervalSince(started), title ?? "nil"))
        print(body)
    }

    // MARK: - Accessibility pipeline check (run from the installed app so it has AX permission)

    private static var report: [String] = []
    private static func say(_ line: String) {
        print(line)
        report.append(line)
    }

    private static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private static func axTest() {
        say("AX trusted: \(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else { finishReport(); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aistack-axtest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sample = "I has a apple and their are many reason to go."

        // 1. TextEdit (native NSTextView)
        let txt = dir.appendingPathComponent("AI Stack test.txt")
        try? sample.write(to: txt, atomically: true, encoding: .utf8)
        if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([txt], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            pump(3)
            probe(appBundle: "com.apple.TextEdit", target: "has", fix: "have", typing: false)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.terminate()
        }

        // 2. Chrome textarea and contenteditable
        let pages: [(String, String)] = [
            ("textarea", "<textarea id=t autofocus style='width:600px;height:120px;font-size:18px'>\(sample)</textarea>"),
            ("contenteditable", "<div id=t contenteditable autofocus style='width:600px;min-height:120px;font-size:18px;border:1px solid #999'>\(sample)</div><script>const e=document.getElementById('t');e.focus();</script>"),
        ]
        for (name, body) in pages {
            let html = dir.appendingPathComponent("\(name).html")
            try? "<!doctype html><title>AI Stack \(name) test</title><body>\(body)</body>".write(to: html, atomically: true, encoding: .utf8)
            guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { break }
            NSWorkspace.shared.open([html], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
            pump(4)
            say("— Chrome \(name)")
            probe(appBundle: "com.google.Chrome", target: "has", fix: "have", typing: true)
        }
        finishReport()
    }

    @MainActor
    private static func probe(appBundle: String, target: String, fix: String, typing: Bool) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appBundle).first else {
            say("\(appBundle): not running"); return
        }
        app.activate()
        pump(0.8)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1)
        appElement.set("AXManualAccessibility", kCFBooleanTrue)
        if WritingAssistant.isChromiumBrowser(appBundle) { appElement.set("AXEnhancedUserInterface", kCFBooleanTrue) }
        pump(1.0)
        guard let focused = appElement.focusedElement else { say("\(appBundle): no focused element"); return }
        let role = focused.role ?? "?"
        let editable = WritingAssistant.isEditable(role: role, subrole: focused.subrole)
        say("\(appBundle): focused role=\(role) subrole=\(focused.subrole ?? "-") editable=\(editable)")
        guard let value = focused.value else { say("  value: nil"); return }
        say("  value: \(value.debugDescription.prefix(80))")
        let range = (value as NSString).range(of: target)
        guard range.location != NSNotFound else { say("  target not found"); return }
        say("  frame: \(focused.frame.map { "\($0)" } ?? "nil")")
        say("  bounds(\(target)): \(focused.bounds(for: range).map { "\($0)" } ?? "nil")")
        let selected = focused.setSelectedRange(range)
        pump(0.2)
        say("  setSelectedRange: \(selected) → now \(focused.selectedRange.map { "\($0)" } ?? "nil")")
        let expected = (value as NSString).replacingCharacters(in: range, with: fix)
        if typing {
            KeyboardTyper.replaceSelection(with: fix)
        } else {
            say("  setSelectedText: \(focused.setSelectedText(fix).rawValue)")
        }
        pump(0.6)
        let after = focused.value ?? ""
        say("  replaced via \(typing ? "typing" : "AX"): \(after == expected ? "OK" : "MISMATCH → \(after.debugDescription.prefix(80))")")
    }

    private static func finishReport() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AIStack/axtest.txt")
        try? report.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        doneSignal?.signal()
    }
    nonisolated(unsafe) private static var doneSignal: DispatchSemaphore?
}
