using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace AIStack;

public sealed class Segment
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Speaker { get; set; } = "them"; // "me" | "them"
    public DateTime Start { get; set; }
    public DateTime End { get; set; }
    public string Text { get; set; } = "";
}

public sealed class Meeting
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Title { get; set; } = "Meeting";
    public bool TitleIsAuto { get; set; } = true;
    public DateTime StartedAt { get; set; } = DateTime.UtcNow;
    public DateTime? EndedAt { get; set; }
    public string? App { get; set; }
    public string? Url { get; set; }
    public string Language { get; set; } = "auto";
    public string NotesModel { get; set; } = "opus";
    public List<Segment> Segments { get; set; } = [];
    public string UserNotes { get; set; } = "";
    public string? Notes { get; set; }
    public string Status { get; set; } = "recording"; // recording | processing | ready | failed
    public string? Error { get; set; }
    public string? ExportPath { get; set; }

    [JsonIgnore] public TimeSpan Duration => (EndedAt ?? DateTime.UtcNow) - StartedAt;

    public int WordCount
    {
        get { lock (this) return Segments.Sum(s => s.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length); }
    }

    /// Consecutive segments from one speaker merged into blocks.
    public List<(string speaker, DateTime start, DateTime end, string text)> Blocks()
    {
        List<Segment> ordered;
        lock (this) ordered = Segments.OrderBy(s => s.Start).ToList();
        var blocks = new List<(string speaker, DateTime start, DateTime end, string text)>();
        foreach (var s in ordered)
        {
            if (blocks.Count > 0 && blocks[^1].speaker == s.Speaker && (s.Start - blocks[^1].end).TotalSeconds < 6)
            {
                var last = blocks[^1];
                blocks[^1] = (last.speaker, last.start, s.End > last.end ? s.End : last.end, last.text + " " + s.Text);
            }
            else blocks.Add((s.Speaker, s.Start, s.End, s.Text));
        }
        return blocks;
    }

    public static string Clock(TimeSpan t)
    {
        if (t < TimeSpan.Zero) t = TimeSpan.Zero;
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes:00}:{t.Seconds:00}";
    }

    public string TranscriptText() =>
        string.Join("\n", Blocks().Select(b => $"[{Clock(b.start - StartedAt)}] {(b.speaker == "me" ? "Me" : "Them")}: {b.text}"));
}

public sealed class MeetingStore
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    readonly object gate = new();
    readonly Dictionary<string, Meeting> meetings = new();

    public MeetingStore()
    {
        foreach (var file in Directory.EnumerateFiles(Paths.Meetings, "*.json"))
        {
            try
            {
                var meeting = JsonSerializer.Deserialize<Meeting>(File.ReadAllText(file), Json);
                if (meeting != null) meetings[meeting.Id] = meeting;
            }
            catch (Exception ex) { Log.Error($"Could not read {file}: {ex.Message}"); }
        }
        Log.Info($"Loaded {meetings.Count} meeting(s)");
    }

    public Meeting? Get(string id)
    {
        lock (gate) return meetings.GetValueOrDefault(id);
    }

    public List<Meeting> All()
    {
        lock (gate) return meetings.Values.OrderByDescending(m => m.StartedAt).ToList();
    }

    public void Save(Meeting meeting)
    {
        lock (gate) meetings[meeting.Id] = meeting;
        string json;
        lock (meeting) json = JsonSerializer.Serialize(meeting, Json);
        var path = Path.Combine(Paths.Meetings, meeting.Id + ".json");
        var temp = path + ".tmp";
        lock (gate)
        {
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            File.Move(temp, path, overwrite: true);
        }
    }

    public void Delete(string id)
    {
        lock (gate) meetings.Remove(id);
        try { File.Delete(Path.Combine(Paths.Meetings, id + ".json")); } catch { }
    }

    public string? ExportMarkdown(Meeting meeting)
    {
        try
        {
            Directory.CreateDirectory(Paths.NotesFolder);
            var local = meeting.StartedAt.ToLocalTime();
            var safe = Regex.Replace(meeting.Title, @"[\\/:*?""<>|]", "-").Trim();
            if (safe.Length > 80) safe = safe[..80];
            var path = Path.Combine(Paths.NotesFolder, $"{local:yyyy-MM-dd HHmm} {safe}.md");
            var md = new StringBuilder();
            md.Append($"# {meeting.Title}\n\n*{local:dddd d MMMM yyyy, HH:mm} · {Math.Max(1, (int)meeting.Duration.TotalMinutes)} min");
            if (meeting.App != null) md.Append($" · {meeting.App}");
            md.Append("*\n\n");
            md.Append(meeting.Notes ?? "_No notes generated._").Append('\n');
            if (!string.IsNullOrWhiteSpace(meeting.UserNotes)) md.Append($"\n---\n\n## My notes\n\n{meeting.UserNotes}\n");
            var blocks = meeting.Blocks();
            if (blocks.Count > 0)
            {
                md.Append("\n---\n\n## Transcript\n\n");
                foreach (var b in blocks)
                    md.Append($"**{(b.speaker == "me" ? "Me" : "Them")}** ({Meeting.Clock(b.start - meeting.StartedAt)}): {b.text}\n\n");
            }
            if (meeting.ExportPath != null && meeting.ExportPath != path) { try { File.Delete(meeting.ExportPath); } catch { } }
            File.WriteAllText(path, md.ToString(), new UTF8Encoding(false));
            meeting.ExportPath = path;
            Save(meeting);
            return path;
        }
        catch (Exception ex)
        {
            Log.Error($"Markdown export failed: {ex.Message}");
            return null;
        }
    }
}

static class NotesGenerator
{
    const string SystemPrompt = """
    You are an expert meeting note-taker, like Granola. You turn a raw meeting transcript into crisp, skimmable notes.

    Input notes:
    - The transcript comes from automatic speech recognition, so expect recognition mistakes; infer the intended words from context.
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
    """;

    const string AskPrompt = """
    You answer questions about one meeting using its notes and transcript. Be concise and specific; quote figures, names and decisions exactly. Use Markdown bullets when listing. If the answer isn't in the meeting, say so. If asked to draft something (email, summary, follow-up), write it ready to send.
    """;

    public static string Prompt(Meeting m)
    {
        var sb = new StringBuilder();
        sb.Append($"Meeting: {m.Title}\n");
        sb.Append($"Date: {m.StartedAt.ToLocalTime():dddd d MMMM yyyy, HH:mm}\n");
        sb.Append($"Duration: {Math.Max(1, (int)m.Duration.TotalMinutes)} minutes\n");
        if (m.App != null) sb.Append($"Platform: {m.App}\n");
        var userNotes = m.UserNotes.Trim();
        sb.Append($"\n## My notes\n{(userNotes.Length == 0 ? "(none)" : userNotes)}\n");
        var transcript = m.TranscriptText();
        sb.Append($"\n## Transcript\n{(transcript.Length == 0 ? "(no speech captured)" : transcript)}\n");
        return sb.ToString();
    }

    public static async Task<(string? title, string body)> GenerateAsync(Meeting m)
    {
        var config = new ClaudeConfig(m.NotesModel, SystemPrompt);
        var markdown = await ClaudeCli.Shared.CompleteAsync(Prompt(m), config, TimeSpan.FromMinutes(15));
        return Split(markdown);
    }

    public static (string? title, string body) Split(string markdown)
    {
        var body = markdown.Trim();
        body = Regex.Replace(body, @"^```[a-z]*\n?", "");
        body = Regex.Replace(body, @"\n?```$", "").Trim();
        if (!body.StartsWith("# ")) return (null, body);
        var newline = body.IndexOf('\n');
        var title = (newline < 0 ? body[2..] : body[2..newline]).Trim();
        var rest = newline < 0 ? "" : body[(newline + 1)..].Trim();
        return (title.Length == 0 ? null : title, rest);
    }

    public static Task<string> AnswerAsync(Meeting m, string question)
    {
        var prompt = Prompt(m);
        if (m.Notes != null) prompt += $"\n## Generated notes\n{m.Notes}\n";
        prompt += $"\n## Question\n{question}";
        return ClaudeCli.Shared.CompleteAsync(prompt, new ClaudeConfig("sonnet", AskPrompt), TimeSpan.FromMinutes(5));
    }
}
