import SwiftUI

// MARK: - Block model & parser

enum MDBlock {
    case heading(Int, String)
    case bullet(String, Int)      // text, depth
    case ordered(String, String)  // number, text
    case quote(String)
    case rule
    case code(String)
    case table([[String]])        // rows[0] = header
    case paragraph(String)        // may contain \n; line breaks preserved
}

func parseMarkdownBlocks(_ text: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    let lines = text.components(separatedBy: "\n")
    var para: [String] = []
    func flush() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }

    var i = 0
    while i < lines.count {
        let raw = lines[i]
        let line = raw.trimmingCharacters(in: .whitespaces)

        // fenced code
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            flush()
            let fence = String(line.prefix(3))
            var code: [String] = []
            i += 1
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                code.append(lines[i]); i += 1
            }
            if i < lines.count { i += 1 }  // skip closing fence
            blocks.append(.code(code.joined(separator: "\n")))
            continue
        }

        if line.isEmpty { flush(); i += 1; continue }

        // table: header row followed by separator row
        if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            flush()
            var rows: [[String]] = [parseTableRow(line)]
            i += 2
            while i < lines.count, lines[i].contains("|"),
                  !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(parseTableRow(lines[i])); i += 1
            }
            blocks.append(.table(rows))
            continue
        }

        if let (level, content) = heading(line) { flush(); blocks.append(.heading(level, content)); i += 1; continue }
        if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); i += 1; continue }
        if line.hasPrefix("> ") || line == ">" {
            flush(); blocks.append(.quote(String(line.dropFirst(line == ">" ? 1 : 2)))); i += 1; continue
        }
        if let (t, d) = bullet(raw) { flush(); blocks.append(.bullet(t, d)); i += 1; continue }
        if let (n, t) = ordered(line) { flush(); blocks.append(.ordered(n, t)); i += 1; continue }

        para.append(line); i += 1
    }
    flush()
    return blocks
}

private func heading(_ line: String) -> (Int, String)? {
    guard line.hasPrefix("#") else { return nil }
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    return (hashes, rest.trimmingCharacters(in: .whitespaces))
}

private func bullet(_ raw: String) -> (String, Int)? {
    let depth = raw.prefix { $0 == " " || $0 == "\t" }.count / 2
    let t = raw.trimmingCharacters(in: .whitespaces)
    for p in ["- ", "* ", "+ "] where t.hasPrefix(p) {
        let body = String(t.dropFirst(2))
        if !body.isEmpty { return (body, depth) }
    }
    return nil
}

private func ordered(_ line: String) -> (String, String)? {
    var idx = line.startIndex
    while idx < line.endIndex, line[idx].isNumber { idx = line.index(after: idx) }
    guard idx > line.startIndex, idx < line.endIndex, line[idx] == "." else { return nil }
    let num = String(line[line.startIndex..<idx])
    let rest = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : (num, rest)
}

private func isTableSeparator(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains("-"), t.contains("|") else { return false }
    return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
}

private func parseTableRow(_ line: String) -> [String] {
    var cells = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
    if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
    if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
}

// MARK: - Renderer

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(parseMarkdownBlocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(Self.inline(content))
                .font(level <= 2 ? .headline : .subheadline)
                .fontWeight(.semibold)
                .padding(.top, 2)

        case .bullet(let content, let depth):
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(.secondary)
                TextLines(text: content)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .ordered(let num, let content):
            HStack(alignment: .top, spacing: 7) {
                Text("\(num).").foregroundStyle(.secondary).monospacedDigit()
                TextLines(text: content)
            }
            .padding(.leading, 2)

        case .quote(let content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                TextLines(text: content).foregroundStyle(.secondary)
            }

        case .rule:
            Divider()

        case .code(let code):
            CodeBlock(code: code)

        case .table(let rows):
            TableBlock(rows: rows)

        case .paragraph(let content):
            TextLines(text: content)
        }
    }

    /// 行内 Markdown（粗/斜/行内码/链接）；对行内码加底色 + 等宽。
    static func inline(_ s: String) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var attr = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].backgroundColor = Color(.secondarySystemFill)
            attr[run.range].font = .system(.callout, design: .monospaced)
        }
        return attr
    }
}

/// 逐行渲染，保留换行（Markdown 默认会把单个换行折叠成空格）。
struct TextLines: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer().frame(height: 4)
                } else {
                    Text(MarkdownText.inline(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct CodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownText.inline(cell))
                            .font(.caption)
                            .fontWeight(idx == 0 ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if idx == 0 { Divider() }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
