import SwiftUI

/// Small block-level Markdown renderer for meeting notes (headings, bullets, checklists, numbers).
struct MarkdownView: View {
    let text: String
    /// Called with the source line index when a checklist box is clicked.
    var onToggleCheckbox: ((Int) -> Void)? = nil

    enum Block {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case check(indent: Int, done: Bool, text: String, line: Int)
        case numbered(indent: Int, number: String, text: String)
        case quote(String)
        case rule
        case paragraph(String)
        case gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 10 : 6)
                .padding(.bottom, 2)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
                Self.inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18 + 4)
        case .check(let indent, let done, let text, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    onToggleCheckbox?(line)
                } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                Self.inline(text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18 + 2)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(.secondary).monospacedDigit()
                Self.inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18 + 2)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Self.inline(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, 6)
        case .paragraph(let text):
            Self.inline(text).fixedSize(horizontal: false, vertical: true)
        case .gap:
            Spacer().frame(height: 4)
        }
    }

    static func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let leading = raw.prefix { $0 == " " || $0 == "\t" }
            let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if case .gap = blocks.last {} else if !blocks.isEmpty { blocks.append(.gap) }
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                if level <= 6, line.dropFirst(level).hasPrefix(" ") {
                    blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
                    continue
                }
            }
            if line == "---" || line == "***" || line == "___" { blocks.append(.rule); continue }
            if let match = line.firstMatch(of: #/^[-*+] \[([ xX])\] (.*)$/#) {
                blocks.append(.check(indent: indent, done: match.1 != " ", text: String(match.2), line: index))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                blocks.append(.bullet(indent: indent, text: String(line.dropFirst(2))))
                continue
            }
            if let match = line.firstMatch(of: #/^(\d+)[.)] (.*)$/#) {
                blocks.append(.numbered(indent: indent, number: "\(match.1).", text: String(match.2)))
                continue
            }
            if line.hasPrefix("> ") { blocks.append(.quote(String(line.dropFirst(2)))); continue }
            blocks.append(.paragraph(line))
        }
        return blocks
    }

    /// Flips "[ ]" ↔ "[x]" on the given source line.
    static func toggleCheckbox(in text: String, line: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        if lines[line].contains("[ ]") {
            lines[line] = lines[line].replacingOccurrences(of: "[ ]", with: "[x]", options: [], range: lines[line].range(of: "[ ]"))
        } else if let range = lines[line].range(of: "[x]") ?? lines[line].range(of: "[X]") {
            lines[line].replaceSubrange(range, with: "[ ]")
        }
        return lines.joined(separator: "\n")
    }
}
