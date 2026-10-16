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
        Task.detached {
            do {
                switch mode {
                case "grammar": try await grammar(extra.first)
                case "transcribe": try await transcribe(extra.first ?? "", language: extra.dropFirst().first ?? "en-GB")
                case "notes": try await notes()
                default: print("unknown mode \(mode)")
                }
            } catch {
                print("FAILED: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
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
}
