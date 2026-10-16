import Foundation
import AppKit

enum Speaker: String, Codable {
    case me, them
    var label: String { self == .me ? "Me" : "Them" }
}

struct Segment: Codable, Identifiable, Hashable {
    var id = UUID()
    var speaker: Speaker
    var start: Date
    var end: Date
    var text: String
}

enum MeetingStatus: String, Codable {
    case recording, processing, ready, failed
}

struct Meeting: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// True while the title is a placeholder that Claude may replace.
    var titleIsAuto: Bool
    var startedAt: Date
    var endedAt: Date?
    var app: String?
    var attendees: [String] = []
    var language: String
    var segments: [Segment] = []
    var userNotes: String = ""
    var notes: String?
    var status: MeetingStatus
    var error: String?
    var exportPath: String?

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(separator: " ").count } }

    /// Consecutive segments from the same speaker merged for display / prompts.
    var blocks: [TranscriptBlock] {
        var result: [TranscriptBlock] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.speaker == segment.speaker, segment.start.timeIntervalSince(last.end) < 6 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                result[result.count - 1] = last
            } else {
                result.append(TranscriptBlock(id: segment.id, speaker: segment.speaker, start: segment.start, end: segment.end, text: segment.text))
            }
        }
        return result
    }

    func transcriptText() -> String {
        blocks.map { "[\(Self.clock($0.start.timeIntervalSince(startedAt)))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

struct TranscriptBlock: Identifiable, Hashable {
    let id: UUID
    let speaker: Speaker
    let start: Date
    var end: Date
    var text: String
}

/// Meetings are stored as one JSON file each in ~/Library/Application Support/AIStack/Meetings,
/// and finished notes are also exported as Markdown to the user's notes folder.
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    private let directory = AppPaths.meetings
    private let ioQueue = DispatchQueue(label: "aistack.meetings.io")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() { load() }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Meeting] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), var meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            if meeting.status == .recording || meeting.status == .processing {
                // The app quit mid-meeting: keep what was captured and let the user generate notes.
                meeting.status = meeting.notes == nil ? .failed : .ready
                meeting.error = meeting.notes == nil ? "Recording was interrupted. You can still generate notes from the transcript." : nil
                if meeting.endedAt == nil { meeting.endedAt = meeting.segments.last?.end ?? meeting.startedAt }
                persist(meeting)
            }
            loaded.append(meeting)
        }
        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
        Log.info("Loaded \(meetings.count) meeting(s)", "notes")
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func upsert(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        persist(meeting)
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var meeting = meeting(id) else { return }
        change(&meeting)
        upsert(meeting)
    }

    func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        let url = fileURL(id)
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func persist(_ meeting: Meeting) {
        guard let data = try? encoder.encode(meeting) else { return }
        let url = fileURL(meeting.id)
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Markdown export

    @discardableResult
    func exportMarkdown(_ id: UUID) -> URL? {
        guard let meeting = meeting(id) else { return nil }
        let folder = AppSettings.shared.notesFolderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.error("Cannot create notes folder: \(error.localizedDescription)", "notes")
            return nil
        }
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HHmm"
            return f.string(from: meeting.startedAt)
        }()
        let safeTitle = meeting.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
        let url = folder.appendingPathComponent("\(stamp) \(safeTitle).md")

        let dateText = meeting.startedAt.formatted(date: .complete, time: .shortened)
        var md = "# \(meeting.title)\n\n"
        md += "*\(dateText) · \(Int(meeting.duration / 60)) min"
        if let app = meeting.app { md += " · \(app)" }
        md += "*\n\n"
        if !meeting.attendees.isEmpty { md += "**Attendees:** \(meeting.attendees.joined(separator: ", "))\n\n" }
        md += (meeting.notes ?? "_No notes generated._") + "\n"
        if !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n---\n\n## My notes\n\n\(meeting.userNotes)\n"
        }
        if !meeting.segments.isEmpty {
            md += "\n---\n\n## Transcript\n\n"
            for block in meeting.blocks {
                md += "**\(block.speaker.label)** (\(Meeting.clock(block.start.timeIntervalSince(meeting.startedAt)))): \(block.text)\n\n"
            }
        }
        do {
            if let old = meeting.exportPath, old != url.path { try? FileManager.default.removeItem(atPath: old) }
            try md.write(to: url, atomically: true, encoding: .utf8)
            update(id) { $0.exportPath = url.path }
            return url
        } catch {
            Log.error("Markdown export failed: \(error.localizedDescription)", "notes")
            return nil
        }
    }
}
