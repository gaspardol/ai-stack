import AppKit
import AVFoundation
import Combine

/// Runs one live meeting: mic + system audio → on-device transcription → Claude notes at the end.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var live: Meeting?
    @Published private(set) var volatileMe = ""
    @Published private(set) var volatileThem = ""
    @Published private(set) var isRecording = false
    @Published private(set) var processing = Set<UUID>()
    @Published private(set) var captureWarning: String?
    private(set) var startedAutomatically = false

    private let store: MeetingStore
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var transcriberMe: LiveTranscriber?
    private var transcriberThem: LiveTranscriber?
    private var saveTimer: Timer?
    /// Meetings that were stopped but whose transcribers are still flushing their last results.
    private var finalizing: [UUID: Meeting] = [:]

    init(store: MeetingStore) {
        self.store = store
    }

    var isBusy: Bool { isRecording || !processing.isEmpty }

    func start(app: String?, suggestedTitle: String?, automatic: Bool) {
        guard !isRecording else { return }
        let event = CalendarHelper.shared.currentEvent()
        let title = event?.title ?? suggestedTitle ?? Self.placeholderTitle(app: app)
        let meeting = Meeting(title: title, titleIsAuto: event == nil && suggestedTitle == nil, startedAt: Date(),
                              app: app, attendees: event?.attendees ?? [], language: AppSettings.shared.notesLanguage,
                              status: .recording)
        live = meeting
        isRecording = true
        startedAutomatically = automatic
        captureWarning = nil
        store.upsert(meeting)
        Log.info("Recording started: \(title) [\(app ?? "manual")]", "notes")
        Notifier.recordingStarted(meeting)

        saveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let meeting = self?.live { self?.store.upsert(meeting) }
            }
        }
        Task { await startPipelines(languageID: meeting.language, meetingID: meeting.id) }
    }

    private func startPipelines(languageID: String, meetingID: UUID) async {
        let me = LiveTranscriber(speaker: .me)
        let them = LiveTranscriber(speaker: .them)
        for transcriber in [me, them] {
            transcriber.onFinal = { [weak self] segment in
                Task { @MainActor in self?.append(segment, to: meetingID) }
            }
            transcriber.onVolatile = { [weak self, speaker = transcriber.speaker] text in
                Task { @MainActor in
                    guard self?.live?.id == meetingID else { return }
                    if speaker == .me { self?.volatileMe = text } else { self?.volatileThem = text }
                }
            }
        }
        do {
            try await me.start(languageID: languageID)
            try await them.start(languageID: languageID)
        } catch {
            Log.error("Transcription unavailable: \(error.localizedDescription)", "notes")
            captureWarning = "Transcription unavailable: \(error.localizedDescription)"
            return
        }
        guard isRecording, live?.id == meetingID else {
            await me.finish()
            await them.finish()
            return
        }
        transcriberMe = me
        transcriberThem = them

        let mic = MicCapture()
        mic.onBuffer = { [weak me] buffer in me?.append(buffer) }
        do {
            try mic.start()
            self.mic = mic
        } catch {
            Log.error("Mic capture failed: \(error.localizedDescription)", "notes")
            captureWarning = "Microphone unavailable — check permissions in Setup."
        }

        let system = SystemAudioCapture()
        system.onBuffer = { [weak them] buffer in them?.append(buffer) }
        do {
            try system.start()
            self.system = system
        } catch {
            Log.error("System audio capture failed: \(error.localizedDescription)", "notes")
            captureWarning = "Call audio unavailable — only your microphone is transcribed."
        }
    }

    private func append(_ segment: Segment, to meetingID: UUID) {
        if live?.id == meetingID {
            live?.segments.append(segment)
        } else if finalizing[meetingID] != nil {
            finalizing[meetingID]?.segments.append(segment)
        } else {
            // Final results that arrive after stop() handed the meeting over to the store.
            store.update(meetingID) { $0.segments.append(segment) }
        }
    }

    func updateLive(_ change: (inout Meeting) -> Void) {
        guard var meeting = live else { return }
        change(&meeting)
        live = meeting
    }

    func stop() {
        guard isRecording, var meeting = live else { return }
        isRecording = false
        saveTimer?.invalidate()
        saveTimer = nil
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        let me = transcriberMe, them = transcriberThem
        transcriberMe = nil
        transcriberThem = nil

        meeting.endedAt = Date()
        meeting.status = .processing
        finalizing[meeting.id] = meeting
        live = nil
        volatileMe = ""
        volatileThem = ""
        processing.insert(meeting.id)
        store.upsert(meeting)
        Log.info("Recording stopped: \(meeting.title)", "notes")

        Task {
            async let a: Void = me?.finish() ?? ()
            async let b: Void = them?.finish() ?? ()
            _ = await (a, b)
            try? await Task.sleep(nanoseconds: 300_000_000) // let the last result hops land
            guard let final = self.finalizing.removeValue(forKey: meeting.id) else { return }
            self.store.upsert(final)
            await self.generateNotes(for: final.id)
        }
    }

    func generateNotes(for id: UUID) async {
        guard let meeting = store.meeting(id) else { return }
        processing.insert(id)
        defer { processing.remove(id) }
        store.update(id) { $0.status = .processing; $0.error = nil }

        let hasContent = meeting.wordCount >= 8 || !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else {
            store.update(id) {
                $0.status = .ready
                $0.notes = "_Not enough speech was captured to write notes._"
            }
            return
        }
        do {
            let markdown = try await NotesGenerator.generate(for: meeting)
            let (title, body) = NotesGenerator.split(markdown)
            store.update(id) {
                if $0.titleIsAuto, let title { $0.title = title; $0.titleIsAuto = false }
                $0.notes = body
                $0.status = .ready
            }
            store.exportMarkdown(id)
            if let done = store.meeting(id) { Notifier.notesReady(done) }
        } catch {
            Log.error("Notes generation failed: \(error.localizedDescription)", "notes")
            store.update(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
            }
            Notifier.notesFailed(meeting, error: error.localizedDescription)
        }
    }

    static func placeholderTitle(app: String?) -> String {
        let time = Date().formatted(date: .omitted, time: .shortened)
        if let app { return "\(app) call · \(time)" }
        return "Meeting · \(time)"
    }
}

enum NotesGenerator {
    static let systemPrompt = """
    You are an expert meeting note-taker, like Granola. You turn a raw meeting transcript into crisp, skimmable notes.

    Input notes:
    - The transcript comes from on-device speech recognition, so expect recognition mistakes; infer the intended words from context.
    - "Me" is the user (their microphone). "Them" is everyone else on the call (computer audio), possibly several people merged; use names when the conversation reveals them.
    - If the user speaks through loudspeakers, some "Them" speech may be duplicated under "Me"; ignore such echoes.
    - The user may have typed rough notes during the meeting. They show what matters most to the user: cover every point they wrote, expand it with details from the transcript, and organise the notes around them.

    Write Markdown:
    - Line 1: "# " + a short, specific title for the meeting (max 8 words, no date).
    - Then a 1–2 sentence summary paragraph (no heading).
    - Then "## " sections grouped by topic (not strictly chronological). Use concise bullets, nested where useful. Capture decisions, numbers, dates, names, owners, risks and open questions.
    - End with "## Action items" as a checklist: "- [ ] **Owner** — task (deadline if mentioned)". Use "You" for the user. Omit this section if there are none.
    - Write in the main language spoken in the meeting.
    - Be faithful: never invent facts, and never add details nobody said (e.g. weekdays, years, owners). If something is unclear, say so briefly.
    Output only the Markdown, no preamble, no code fences.
    """

    static func generate(for meeting: Meeting) async throws -> String {
        let config = ClaudeRequestConfig(model: AppSettings.shared.notesModel, systemPrompt: systemPrompt)
        return try await ClaudeCLI.shared.complete(prompt(for: meeting), config: config, timeout: 900)
    }

    static func prompt(for meeting: Meeting) -> String {
        var text = "Meeting: \(meeting.title)\n"
        text += "Date: \(meeting.startedAt.formatted(date: .complete, time: .shortened))\n"
        text += "Duration: \(max(1, Int(meeting.duration / 60))) minutes\n"
        if let app = meeting.app { text += "Platform: \(app)\n" }
        if !meeting.attendees.isEmpty { text += "Calendar attendees: \(meeting.attendees.joined(separator: ", "))\n" }
        let userNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "\n## My notes\n\(userNotes.isEmpty ? "(none)" : userNotes)\n"
        text += "\n## Transcript\n\(meeting.segments.isEmpty ? "(no speech captured)" : meeting.transcriptText())\n"
        return text
    }

    /// Splits a leading "# Title" line off the generated notes.
    static func split(_ markdown: String) -> (title: String?, body: String) {
        var body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.replacingOccurrences(of: #"^```[a-z]*\n?"#, with: "", options: .regularExpression)
            body = body.replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
        }
        guard body.hasPrefix("# ") else { return (nil, body) }
        let lines = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = String(lines[0].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (title.isEmpty ? nil : title, rest)
    }

    static func answer(_ question: String, about meeting: Meeting) async throws -> String {
        let system = """
        You answer questions about one meeting using its notes and transcript. Be concise and specific; quote figures, names \
        and decisions exactly. Use Markdown bullets when listing. If the answer isn't in the meeting, say so. \
        If asked to draft something (email, summary, follow-up), write it ready to send.
        """
        var prompt = NotesGenerator.prompt(for: meeting)
        if let notes = meeting.notes { prompt += "\n## Generated notes\n\(notes)\n" }
        prompt += "\n## Question\n\(question)"
        let config = ClaudeRequestConfig(model: "sonnet", systemPrompt: system)
        return try await ClaudeCLI.shared.complete(prompt, config: config, timeout: 300)
    }
}
