import Foundation

enum IssueKind: String {
    case error   // red: spelling / grammar / punctuation
    case style   // blue: awkward or unclear phrasing
}

/// An issue located inside one paragraph (UTF-16 offsets relative to the paragraph).
struct ParagraphIssue: Hashable {
    let kind: IssueKind
    let local: NSRange
    let text: String
    let fix: String
    let why: String
}

/// An issue positioned in the full text of the focused field.
struct Issue: Identifiable, Equatable {
    let id: String
    let kind: IssueKind
    var range: NSRange
    let text: String
    let fix: String
    let why: String
    let paragraph: String
    let local: NSRange

    init(paragraph: String, offset: Int, _ item: ParagraphIssue) {
        kind = item.kind
        range = NSRange(location: offset + item.local.location, length: item.local.length)
        text = item.text
        fix = item.fix
        why = item.why
        self.paragraph = paragraph
        local = item.local
        id = "\(paragraph.hashValue)|\(item.local.location)|\(item.local.length)|\(item.fix.hashValue)"
    }

    func shifted(by delta: Int) -> Issue {
        var copy = self
        copy.range.location += delta
        return copy
    }
}

/// Splits text into paragraphs, asks Claude about the ones it hasn't seen, and caches results by
/// paragraph text so typing in one paragraph never re-checks the others.
final class GrammarEngine {
    private var cache: [String: [ParagraphIssue]] = [:]
    private var cacheOrder: [String] = []
    private var failedAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    private var ignored = Set<String>()

    static let systemPrompt = """
    You are the proofreading engine of a writing assistant like Grammarly. The user is typing in another app; you get their text as numbered paragraphs and return the spans to underline.

    Two kinds of issues:
    - "error" (red underline): spelling mistakes, typos, grammar errors (agreement, tense, articles, prepositions, conjugation), wrong/missing/duplicated words, clearly wrong punctuation or capitalisation.
    - "style" (blue underline): awkward, unclear, wordy, redundant or unnatural phrasing that a skilled editor would rewrite. Propose a clearly better alternative with the same meaning and tone. Look actively for these: filler ("basically", "in order to", "at this point in time"), clumsy sentence structure, passive constructions that hurt clarity, repetition.

    Rules:
    - Keep each paragraph's language (English, French, ...) in fixes. Respect the writer's variant (British vs American) and register (casual chat vs formal email).
    - Never flag names, brands, URLs, emails, code, hashtags, emoji or deliberate informal style.
    - "text" must be copied EXACTLY from the paragraph (same characters, case, spacing). Errors: only the wrong word(s); duplicated words: include both copies (e.g. "to to" -> "to"). Style: the phrase or full sentence to rewrite.
    - "fix" replaces "text" and must read correctly in place: check capitalisation and the words around the span. It must differ from "text".
    - "before": up to 4 words immediately preceding "text" in the same paragraph, copied exactly ("" only if "text" starts the paragraph).
    - "why": 2-8 words, in English.
    - Real errors only; spans must not overlap; at most 2 style issues per paragraph.

    Reply with ONLY minified JSON (no prose, no code fences):
    {"issues":[{"p":<paragraph id number>,"type":"error"|"style","text":"...","before":"...","fix":"...","why":"..."}]}
    Nothing to report: {"issues":[]}
    """

    static func requestConfig(model: String) -> ClaudeRequestConfig {
        ClaudeRequestConfig(model: model, systemPrompt: systemPrompt, effort: "low", disableThinking: true, keepWarm: true)
    }

    // MARK: Cache

    func cached(_ paragraph: String) -> [ParagraphIssue]? { cache[paragraph] }

    func store(_ results: [String: [ParagraphIssue]]) {
        for (paragraph, issues) in results {
            if cache[paragraph] == nil { cacheOrder.append(paragraph) }
            cache[paragraph] = issues
            inFlight.remove(paragraph)
            failedAt[paragraph] = nil
        }
        if cacheOrder.count > 800 {
            for old in cacheOrder.prefix(200) { cache[old] = nil }
            cacheOrder.removeFirst(200)
        }
    }

    func markFailed(_ paragraphs: [String]) {
        let now = Date()
        for paragraph in paragraphs {
            inFlight.remove(paragraph)
            failedAt[paragraph] = now
        }
    }

    func ignore(_ issue: Issue) { ignored.insert(ignoreKey(issue)) }
    func isIgnored(_ issue: Issue) -> Bool { ignored.contains(ignoreKey(issue)) }
    private func ignoreKey(_ issue: Issue) -> String { "\(issue.paragraph)\u{1}\(issue.text)\u{1}\(issue.fix)" }

    /// After accepting suggestions we already know the result for the new paragraph text(s),
    /// so they aren't re-checked (and don't sprout fresh suggestions).
    func recordApplied(_ applied: [Issue]) {
        var results: [String: [ParagraphIssue]] = [:]
        for (paragraph, fixes) in Dictionary(grouping: applied, by: \.paragraph) {
            guard let items = cache[paragraph] else { continue }
            let source = paragraph as NSString
            let sorted = fixes.sorted { $0.local.location < $1.local.location }
            guard sorted.allSatisfy({ NSMaxRange($0.local) <= source.length }) else { continue }
            var updated = ""
            var position = 0
            for fix in sorted {
                updated += source.substring(with: NSRange(location: position, length: fix.local.location - position)) + fix.fix
                position = NSMaxRange(fix.local)
            }
            updated += source.substring(from: position)
            var remaining: [ParagraphIssue] = []
            for item in items {
                if sorted.contains(where: { NSIntersectionRange($0.local, item.local).length > 0 }) { continue }
                let delta = sorted.filter { NSMaxRange($0.local) <= item.local.location }
                    .reduce(0) { $0 + ($1.fix as NSString).length - $1.local.length }
                remaining.append(ParagraphIssue(kind: item.kind,
                                                local: NSRange(location: item.local.location + delta, length: item.local.length),
                                                text: item.text, fix: item.fix, why: item.why))
            }
            results[updated] = remaining
        }
        store(results)
    }

    /// Paragraphs that still need a check, closest to the caret first. Marks them in flight.
    func paragraphsToCheck(in text: String, caret: Int) -> [String] {
        let now = Date()
        var seen = Set<String>()
        let candidates = Self.paragraphs(text).filter { item in
            guard seen.insert(item.text).inserted else { return false }
            guard cache[item.text] == nil, !inFlight.contains(item.text), Self.isCheckable(item.text) else { return false }
            if let failed = failedAt[item.text], now.timeIntervalSince(failed) < 45 { return false }
            return true
        }
        let sorted = candidates.sorted { a, b in
            distance(a.range, caret) < distance(b.range, caret)
        }
        var batch: [String] = []
        var total = 0
        for item in sorted {
            let length = (item.text as NSString).length
            if !batch.isEmpty && (total + length > 5000 || batch.count >= 16) { break }
            batch.append(item.text)
            total += length
        }
        inFlight.formUnion(batch)
        return batch
    }

    private func distance(_ range: NSRange, _ caret: Int) -> Int {
        if NSLocationInRange(caret, range) || caret == NSMaxRange(range) { return 0 }
        return caret < range.location ? range.location - caret : caret - NSMaxRange(range)
    }

    // MARK: Text helpers

    static func paragraphs(_ text: String) -> [(text: String, range: NSRange)] {
        let string = text as NSString
        var result: [(String, NSRange)] = []
        var start = 0
        let length = string.length
        var index = 0
        while index <= length {
            let isBreak: Bool
            if index == length {
                isBreak = true
            } else {
                let c = string.character(at: index)
                isBreak = c == 10 || c == 13 || c == 0x2028 || c == 0x2029
            }
            if isBreak {
                let range = NSRange(location: start, length: index - start)
                if range.length > 0 { result.append((string.substring(with: range), range)) }
                start = index + 1
            }
            index += 1
        }
        return result
    }

    static func isCheckable(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        if !trimmed.contains(" ") && (trimmed.hasPrefix("http") || trimmed.contains("@") || trimmed.contains("/")) { return false }
        return true
    }

    // MARK: Claude request

    static func check(_ paragraphs: [String], appName: String, model: String) async throws -> [String: [ParagraphIssue]] {
        var prompt = "App: \(appName)\n"
        for (index, paragraph) in paragraphs.enumerated() {
            prompt += "<p id=\"\(index + 1)\">\(paragraph)</p>\n"
        }
        let started = Date()
        let raw = try await ClaudeCLI.shared.complete(prompt, config: requestConfig(model: model), timeout: 60)
        let items = try parse(raw)
        Log.info(String(format: "checked %d paragraph(s) in %.2fs → %d issue(s)", paragraphs.count, Date().timeIntervalSince(started), items.count), "writing")

        var result: [String: [ParagraphIssue]] = [:]
        for paragraph in paragraphs { result[paragraph] = [] }
        var taken: [String: [NSRange]] = [:]
        for item in items {
            guard item.p >= 1, item.p <= paragraphs.count else { continue }
            let paragraph = paragraphs[item.p - 1]
            guard let (range, actual) = locate(item.text, before: item.before, in: paragraph, taken: taken[paragraph] ?? []),
                  actual != item.fix else { continue }
            taken[paragraph, default: []].append(range)
            result[paragraph]?.append(ParagraphIssue(kind: item.kind, local: range, text: actual, fix: item.fix, why: item.why))
        }
        return result
    }

    private struct RawIssue {
        let p: Int
        let kind: IssueKind
        let text: String
        let before: String
        let fix: String
        let why: String
    }

    private static func parse(_ raw: String) throws -> [RawIssue] {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") {
            body = String(body[start...end])
        }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["issues"] as? [[String: Any]] else {
            Log.error("Unparseable grammar response: \(raw.prefix(300))", "writing")
            throw ClaudeError.failed("Unexpected response from Claude")
        }
        return list.compactMap { entry in
            let p: Int? = (entry["p"] as? Int) ?? (entry["p"] as? String).flatMap { Int($0) } ?? (entry["p"] as? Double).map { Int($0) }
            guard let p, let text = entry["text"] as? String, !text.isEmpty,
                  let fix = entry["fix"] as? String, fix != text, fix.count < 800 else { return nil }
            let kind: IssueKind = (entry["type"] as? String) == "style" ? .style : .error
            return RawIssue(p: p, kind: kind, text: text, before: entry["before"] as? String ?? "",
                            fix: fix, why: entry["why"] as? String ?? "")
        }
    }

    /// Finds the span in the paragraph, using `before` to pick the right occurrence.
    static func locate(_ text: String, before: String, in paragraph: String, taken: [NSRange]) -> (NSRange, String)? {
        let string = paragraph as NSString
        func occurrences(_ options: NSString.CompareOptions) -> [NSRange] {
            var found: [NSRange] = []
            var search = NSRange(location: 0, length: string.length)
            while search.length > 0 {
                let range = string.range(of: text, options: options, range: search)
                if range.location == NSNotFound { break }
                found.append(range)
                let next = range.location + max(range.length, 1)
                guard next < string.length else { break }
                search = NSRange(location: next, length: string.length - next)
            }
            return found
        }
        var candidates = occurrences([])
        if candidates.isEmpty { candidates = occurrences([.caseInsensitive, .diacriticInsensitive]) }
        let free = candidates.filter { candidate in !taken.contains { NSIntersectionRange($0, candidate).length > 0 } }
        guard !free.isEmpty else { return nil }
        let anchor = before.trimmingCharacters(in: .whitespaces)
        var chosen = free[0]
        if !anchor.isEmpty, let match = free.first(where: { candidate in
            string.substring(to: candidate.location).trimmingCharacters(in: .whitespaces).hasSuffix(anchor)
        }) {
            chosen = match
        }
        return (chosen, string.substring(with: chosen))
    }
}
