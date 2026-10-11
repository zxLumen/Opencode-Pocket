import SwiftUI

/// Renders a message body: fenced ```code``` blocks as monospace boxes,
/// everything else as Markdown (bold / italic / inline code / lists / links).
enum MDBlock: Hashable {
    case text(String)
    case code(String)
}

func parseMarkdownBlocks(_ text: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var buf: [String] = []
    var code: [String] = []
    var inCode = false

    for line in text.components(separatedBy: "\n") {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            if inCode {
                blocks.append(.code(code.joined(separator: "\n")))
                code = []
                inCode = false
            } else {
                if !buf.isEmpty { blocks.append(.text(buf.joined(separator: "\n"))); buf = [] }
                inCode = true
            }
            continue
        }
        if inCode { code.append(line) } else { buf.append(line) }
    }
    if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
    if !buf.isEmpty { blocks.append(.text(buf.joined(separator: "\n"))) }
    return blocks
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseMarkdownBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    Text(Self.attributed(t))
                case .code(let c):
                    CodeBlock(code: c)
                }
            }
        }
    }

    static func attributed(_ s: String) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .full
        opts.allowsExtendedAttributes = true
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
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
