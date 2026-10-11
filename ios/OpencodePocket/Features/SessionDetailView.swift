import SwiftUI

struct SessionDetailView: View {
    let sessionID: String
    @Environment(PocketStore.self) private var store
    @State private var messages: [Message] = []

    private var session: Session? { store.session(sessionID) }
    private var permissions: [PendingPermission] { store.pendingPermissions.filter { $0.sessionID == sessionID } }
    private var questions: [PendingQuestion] { store.pendingQuestions.filter { $0.sessionID == sessionID } }
    private var isRunning: Bool { store.activeIDs.contains(sessionID) }

    var body: some View {
        List {
            Section {
                header
                if !permissions.isEmpty || !questions.isEmpty {
                    ForEach(permissions) { PermissionCard(permission: $0) }
                    ForEach(questions) { QuestionCard(question: $0) }
                }
            }

            Section("消息") {
                ForEach(messages) { message in
                    MessageRow(message: message)
                }
                if let live = store.liveText[sessionID], !live.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("实时", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption2).foregroundStyle(.green)
                        Text(live).font(.callout)
                    }
                }
                if messages.isEmpty && (store.liveText[sessionID] ?? "").isEmpty {
                    Text("暂无消息").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session?.displayTitle ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                agentMenu
                modelMenu
                Button {
                    Task { await store.interrupt(sessionID: sessionID) }
                } label: { Image(systemName: "stop.circle") }
                .disabled(!isRunning)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerView(sessionID: sessionID)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                Text(isRunning ? "运行中" : "空闲").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let cost = session?.cost, cost > 0 {
                    Text(String(format: "$%.3f", cost)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let dir = session?.directory {
                Text(dir).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let t = session?.tokens {
                Text("in \(t.input ?? 0) · out \(t.output ?? 0) · reason \(t.reasoning ?? 0)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var agentMenu: some View {
        Menu {
            ForEach(store.agents) { agent in
                Button(agent.displayName) {
                    Task { await store.switchAgent(sessionID: sessionID, agent: agent.id) }
                }
            }
        } label: { Image(systemName: "person.crop.circle") }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(store.distinctModels, id: \.label) { model in
                Button(model.label) {
                    Task { await store.switchModel(sessionID: sessionID, model: model) }
                }
            }
        } label: { Image(systemName: "cpu") }
    }

    private func reload() async {
        messages = await store.loadMessages(sessionID: sessionID)
    }
}

struct MessageRow: View {
    let message: Message

    private var text: String {
        (message.content ?? []).filter { $0.type == "text" }.compactMap { $0.text }.joined(separator: "\n")
    }
    private var reasoning: String {
        (message.content ?? []).filter { $0.type == "reasoning" }.compactMap { $0.text }.joined(separator: "\n")
    }
    private var tools: [String] {
        (message.content ?? []).filter { $0.type == "tool" || $0.type == "tool-call" }.compactMap { $0.text }
    }

    private var roleLabel: String {
        switch message.type {
        case "user": return "你"
        case "assistant": return "助手"
        case "idle": return "空闲"
        case "agent-switched": return "切换 Agent"
        default: return message.type ?? "事件"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(roleLabel).font(.caption2.bold()).foregroundStyle(message.isUser ? Color.blue : Color.secondary)
                Spacer()
                if let agent = message.agent { Text(agent).font(.caption2).foregroundStyle(.tertiary) }
            }
            if !text.isEmpty { Text(text).font(.callout).textSelection(.enabled) }
            if !tools.isEmpty {
                ForEach(tools, id: \.self) { Text("🛠 \($0)").font(.caption).foregroundStyle(.secondary) }
            }
            if !reasoning.isEmpty {
                DisclosureGroup("思考") {
                    Text(reasoning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }
}
