import SwiftUI

struct PermissionCard: View {
    @Environment(PocketStore.self) private var store
    let permission: PendingPermission
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("需要审批", systemImage: "lock.shield")
                .font(.subheadline.bold())
            Text(permission.title).font(.callout)
            if !permission.resources.isEmpty {
                Text(permission.resources.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack(spacing: 8) {
                Button("允许一次") { reply("once") }
                Button("始终允许") { reply("always") }
                Button("拒绝", role: .destructive) { reply("reject") }
            }
            .buttonStyle(.bordered)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private func reply(_ value: String) {
        busy = true
        Task {
            await store.replyPermission(permission, reply: value)
            busy = false
        }
    }
}

struct QuestionCard: View {
    @Environment(PocketStore.self) private var store
    let question: PendingQuestion
    @State private var selections: [[String]] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("需要回答", systemImage: "questionmark.bubble")
                .font(.subheadline.bold())

            ForEach(Array(question.questions.enumerated()), id: \.offset) { index, info in
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.header).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(info.question).font(.callout)
                    ForEach(info.options, id: \.label) { option in
                        Button {
                            toggle(index: index, label: option.label, multiple: info.multiple == true)
                        } label: {
                            HStack {
                                Image(systemName: isSelected(index: index, label: option.label) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let d = option.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button("提交") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                Button("拒绝", role: .destructive) { reject() }
                    .buttonStyle(.bordered)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: setup)
    }

    private func setup() {
        if selections.count != question.questions.count {
            selections = Array(repeating: [], count: question.questions.count)
        }
    }

    private func isSelected(index: Int, label: String) -> Bool {
        guard index < selections.count else { return false }
        return selections[index].contains(label)
    }

    private func toggle(index: Int, label: String, multiple: Bool) {
        guard index < selections.count else { return }
        if multiple {
            if selections[index].contains(label) {
                selections[index].removeAll { $0 == label }
            } else {
                selections[index].append(label)
            }
        } else {
            selections[index] = [label]
        }
    }

    private func submit() {
        busy = true
        Task {
            await store.replyQuestion(question, answers: selections)
            busy = false
        }
    }

    private func reject() {
        busy = true
        Task {
            await store.rejectQuestion(question)
            busy = false
        }
    }
}
