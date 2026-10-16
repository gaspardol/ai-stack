import AppKit
import SwiftUI

struct NotesRootView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var navigation: NotesNavigation
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            if let id = navigation.selection, store.meeting(id) != nil || recorder.live?.id == id {
                MeetingDetailView(id: id).id(id)
            } else {
                EmptyNotesView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search meetings", text: $search).textFieldStyle(.plain)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                if recorder.isRecording {
                    Button { recorder.stop() } label: { Image(systemName: "stop.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                        .help("Stop recording and write notes")
                } else {
                    Button {
                        recorder.start(app: nil, suggestedTitle: nil, automatic: false)
                        navigation.selection = recorder.live?.id
                    } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.plain)
                        .help("Start taking notes now")
                }
            }
            .padding(10)

            List(selection: $navigation.selection) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, isLive: recorder.live?.id == meeting.id,
                                       isProcessing: recorder.processing.contains(meeting.id))
                                .tag(meeting.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        if navigation.selection == meeting.id { navigation.selection = nil }
                                        store.delete(meeting.id)
                                    }
                                    .disabled(recorder.live?.id == meeting.id)
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var meetings = store.meetings
        if let live = recorder.live, let index = meetings.firstIndex(where: { $0.id == live.id }) { meetings[index] = live }
        let filtered = query.isEmpty ? meetings : meetings.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.notes ?? "").localizedCaseInsensitiveContains(query)
                || $0.userNotes.localizedCaseInsensitiveContains(query)
        }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            return (title, grouped[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isLive: Bool
    let isProcessing: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1).fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                    if !isLive { Text("· \(max(1, Int(meeting.duration / 60))) min") }
                    if let app = meeting.app { Text("· \(app)").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isLive {
                Circle().fill(.red).frame(width: 8, height: 8)
            } else if isProcessing {
                ProgressView().controlSize(.small)
            } else if meeting.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }
}

struct EmptyNotesView: View {
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var navigation: NotesNavigation

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Your meeting notes live here").font(.title3.weight(.semibold))
            Text("AI Stack starts taking notes automatically when a call begins in Google Meet, Teams, Zoom, FaceTime, Slack and more. Audio is transcribed on your Mac, then Claude writes the notes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Start notes now") {
                recorder.start(app: nil, suggestedTitle: nil, automatic: false)
                navigation.selection = recorder.live?.id
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail

private enum DetailTab: String, CaseIterable, Identifiable {
    case notes = "Notes", transcript = "Transcript", mine = "My notes"
    var id: String { rawValue }
}

struct QAItem: Identifiable {
    let id = UUID()
    let question: String
    var answer: String?
    var error: String?
}

struct MeetingDetailView: View {
    @EnvironmentObject var store: MeetingStore
    @EnvironmentObject var recorder: MeetingRecorder
    let id: UUID

    @State private var tab: DetailTab = .notes
    @State private var editing = false
    @State private var draft = ""
    @State private var question = ""
    @State private var qa: [QAItem] = []
    @State private var asking = false

    private var isLive: Bool { recorder.live?.id == id }
    private var meeting: Meeting? { isLive ? recorder.live : store.meeting(id) }

    var body: some View {
        if let meeting {
            VStack(spacing: 0) {
                header(meeting)
                Divider()
                if isLive {
                    LiveMeetingView()
                } else {
                    Picker("", selection: $tab) {
                        ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    .padding(.vertical, 10)
                    Divider()
                    switch tab {
                    case .notes: notesTab(meeting)
                    case .transcript: TranscriptView(meeting: meeting, volatileMe: "", volatileThem: "", followLive: false)
                    case .mine: myNotesTab(meeting)
                    }
                    Divider()
                    askBar(meeting)
                }
            }
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: Binding(
                get: { meeting.title },
                set: { newValue in
                    if isLive { recorder.updateLive { $0.title = newValue; $0.titleIsAuto = false } }
                    else { store.update(id) { $0.title = newValue; $0.titleIsAuto = false } }
                }))
                .textFieldStyle(.plain)
                .font(.title2.weight(.bold))
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if !isLive { Text("· \(max(1, Int(meeting.duration / 60))) min") }
                if let app = meeting.app { Text("· \(app)") }
                Text("· \(AppSettings.languageName(meeting.language))")
                if !meeting.attendees.isEmpty {
                    Text("· \(meeting.attendees.prefix(4).joined(separator: ", "))\(meeting.attendees.count > 4 ? " +\(meeting.attendees.count - 4)" : "")")
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func notesTab(_ meeting: Meeting) -> some View {
        if recorder.processing.contains(id) || meeting.status == .processing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Claude is writing your notes…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if editing {
            VStack(spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        store.update(id) { $0.notes = draft }
                        store.exportMarkdown(id)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                }
                .padding(12)
            }
        } else {
            VStack(spacing: 0) {
                notesToolbar(meeting)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if meeting.status == .failed {
                            Label(meeting.error ?? "Notes couldn't be generated.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Generate notes") { regenerate() }.buttonStyle(.borderedProminent)
                        }
                        if let notes = meeting.notes {
                            MarkdownView(text: notes) { line in
                                store.update(id) { $0.notes = MarkdownView.toggleCheckbox(in: notes, line: line) }
                            }
                        } else if meeting.status != .failed {
                            Text("No notes yet.").foregroundStyle(.secondary)
                            Button("Generate notes") { regenerate() }
                        }
                        if !qa.isEmpty { qaList }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private func notesToolbar(_ meeting: Meeting) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Button { copyNotes(meeting) } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button {
                draft = meeting.notes ?? ""
                editing = true
            } label: { Label("Edit", systemImage: "pencil") }
            Button { regenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
            Button {
                if let url = store.exportMarkdown(id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: { Label("Show File", systemImage: "folder") }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func myNotesTab(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes you typed during the meeting. Click Regenerate in Notes to fold edits in.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { meeting.userNotes }, set: { value in store.update(id) { $0.userNotes = value } }))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
        .padding(20)
    }

    private var qaList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().padding(.vertical, 6)
            ForEach(qa) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.question).fontWeight(.semibold)
                    if let answer = item.answer {
                        MarkdownView(text: answer)
                    } else if let error = item.error {
                        Text(error).foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
            }
        }
    }

    private func askBar(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            TextField("Ask anything about this meeting — e.g. “draft a follow-up email”", text: $question)
                .textFieldStyle(.plain)
                .onSubmit { ask(meeting) }
            if asking { ProgressView().controlSize(.small) }
            Button("Ask") { ask(meeting) }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func ask(_ meeting: Meeting) {
        let text = question.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !asking else { return }
        question = ""
        tab = .notes
        let item = QAItem(question: text)
        qa.append(item)
        asking = true
        Task {
            do {
                let answer = try await NotesGenerator.answer(text, about: meeting)
                if let index = qa.firstIndex(where: { $0.id == item.id }) { qa[index].answer = answer }
            } catch {
                if let index = qa.firstIndex(where: { $0.id == item.id }) { qa[index].error = error.localizedDescription }
            }
            asking = false
        }
    }

    private func regenerate() {
        Task { await recorder.generateNotes(for: id) }
    }

    private func copyNotes(_ meeting: Meeting) {
        let text = "# \(meeting.title)\n\n" + (meeting.notes ?? "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Live meeting

struct LiveMeetingView: View {
    @EnvironmentObject var recorder: MeetingRecorder
    @State private var showTranscript = true

    var body: some View {
        if let meeting = recorder.live {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Meeting.clock(context.date.timeIntervalSince(meeting.startedAt)))
                            .monospacedDigit()
                            .fontWeight(.medium)
                    }
                    Text("Transcribing on-device").foregroundStyle(.secondary).font(.callout)
                    if let warning = recorder.captureWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        AppDelegate.shared.detector.suppressCurrentCall()
                        recorder.stop()
                    } label: {
                        Label("Stop & write notes", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your notes").font(.headline)
                    Text("Jot down anything important. Claude combines it with the transcript when the call ends.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { recorder.live?.userNotes ?? "" },
                                             set: { value in recorder.updateLive { $0.userNotes = value } }))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Divider()
                DisclosureGroup(isExpanded: $showTranscript) {
                    TranscriptView(meeting: meeting, volatileMe: recorder.volatileMe, volatileThem: recorder.volatileThem, followLive: true)
                        .frame(height: 230)
                } label: {
                    Text("Live transcript").font(.headline)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
        }
    }
}

struct TranscriptView: View {
    let meeting: Meeting
    let volatileMe: String
    let volatileThem: String
    let followLive: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if meeting.segments.isEmpty && volatileMe.isEmpty && volatileThem.isEmpty {
                        Text(followLive ? "Listening… the transcript appears here as people speak." : "No transcript.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(meeting.blocks) { block in
                        row(speaker: block.speaker, time: Meeting.clock(block.start.timeIntervalSince(meeting.startedAt)), text: block.text, volatile: false)
                    }
                    if !volatileThem.isEmpty { row(speaker: .them, time: "", text: volatileThem, volatile: true) }
                    if !volatileMe.isEmpty { row(speaker: .me, time: "", text: volatileMe, volatile: true) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, followLive ? 0 : 28)
                .padding(.vertical, 14)
                .textSelection(.enabled)
            }
            .onChange(of: meeting.segments.count) { if followLive { proxy.scrollTo("bottom") } }
            .onChange(of: volatileMe + volatileThem) { if followLive { proxy.scrollTo("bottom") } }
        }
    }

    private func row(speaker: Speaker, time: String, text: String, volatile: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(speaker.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(speaker == .me ? Color.accentColor : Color.purple)
                .frame(width: 40, alignment: .leading)
            Text(time).font(.caption).monospacedDigit().foregroundStyle(.tertiary).frame(width: 44, alignment: .leading)
            Text(text)
                .foregroundStyle(volatile ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
