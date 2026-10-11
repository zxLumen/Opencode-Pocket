import SwiftUI
import UIKit

private struct BottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct SessionDetailView: View {
    let sessionID: String
    @Environment(PocketStore.self) private var store
    @State private var messages: [Message] = []
    @State private var follow = true

    private var session: Session? { store.session(sessionID) }
    private var permissions: [PendingPermission] { store.pendingPermissions.filter { $0.sessionID == sessionID } }
    private var questions: [PendingQuestion] { store.pendingQuestions.filter { $0.sessionID == sessionID } }
    private var forms: [FormInfo] { store.pendingForms.filter { $0.sessionID == sessionID } }
    private var isRunning: Bool { store.activeIDs.contains(sessionID) }
    private var live: String { store.liveText[sessionID] ?? "" }
    private var liveR: String { store.liveReasoning[sessionID] ?? "" }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        header

                        if let err = store.lastError, !err.isEmpty {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.red)
                        }

                        ForEach(permissions) { PermissionCard(permission: $0) }
                        ForEach(questions) { QuestionCard(question: $0) }
                        ForEach(forms) { FormCard(form: $0) }

                        ForEach(messages.filter { $0.type != "synthetic" }) { message in
                            MessageRow(message: message).id(message.id)
                        }

                        if !live.isEmpty {
                            LiveBubble(text: live).id("live")
                        }
                        if !liveR.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("实时思考", systemImage: "brain")
                                    .font(.caption2).foregroundStyle(.secondary)
                                MarkdownText(text: liveR).font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(key: BottomYKey.self,
                                                           value: g.frame(in: .named("scroll")).minY)
                                }
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "scroll")
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in follow = false })
                .onTapGesture { dismissKeyboard() }   // 点空白处收起键盘
                .onPreferenceChange(BottomYKey.self) { minY in
                    if minY <= outer.size.height + 30 { follow = true }
                }
                .onChange(of: messages.count) { _, _ in if follow { scrollToBottom(proxy) } }
                .onChange(of: live) { _, _ in if follow { scrollToBottom(proxy) } }
                .onChange(of: store.refreshTick) { _, _ in Task { await reload(); if follow { scrollToBottom(proxy) } } }
                .task(id: isRunning) {
                    await reload()
                    scrollToBottom(proxy, animated: false)
                    while isRunning && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if Task.isCancelled { break }
                        await reload()
                        if follow { scrollToBottom(proxy) }
                    }
                }
                .refreshable { await reload() }
            }
        }
        .navigationTitle(session?.displayTitle ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起") { dismissKeyboard() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                agentMenu
                modelMenu
                Button { Task { await store.interrupt(sessionID: sessionID) } } label: { Image(systemName: "stop.circle") }
                    .disabled(!isRunning)
            }
        }
        .safeAreaInset(edge: .bottom) { ComposerView(sessionID: sessionID) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
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
            Divider()
        }
    }

    private var agentMenu: some View {
        Menu {
            ForEach(store.agents) { agent in
                Button(agent.displayName) { Task { await store.switchAgent(sessionID: sessionID, agent: agent.id) } }
            }
        } label: { Image(systemName: "person.crop.circle") }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(store.distinctModels, id: \.label) { model in
                Button(model.label) { Task { await store.switchModel(sessionID: sessionID, model: model) } }
            }
        } label: { Image(systemName: "cpu") }
    }

    private func reload() async {
        let list = await store.loadMessages(sessionID: sessionID)
        messages = list.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
    }
}

struct LiveBubble: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("实时", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2).foregroundStyle(.green)
            MarkdownText(text: text)
        }
    }
}

struct MessageRow: View {
    let message: Message

    private var bodyText: String { message.displayText }
    private var reasoning: String {
        (message.content ?? []).filter { $0.type == "reasoning" }.compactMap { $0.text }.joined(separator: "\n")
    }
    private var tools: [(name: String, status: String?)] { message.tools }

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
            if message.type == "agent-switched" {
                HStack(spacing: 8) {
                    Divider().frame(width: 16)
                    Text("切换 Agent → \(message.agent ?? "?")")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                }
            } else {
                HStack {
                    Text(roleLabel).font(.caption2.bold())
                        .foregroundStyle(message.isUser ? Color.blue : Color.secondary)
                    Spacer()
                    if let agent = message.agent { Text(agent).font(.caption2).foregroundStyle(.tertiary) }
                }
            }

            if !bodyText.isEmpty {
                MarkdownText(text: bodyText).textSelection(.enabled)
            }

            if !tools.isEmpty {
                DisclosureGroup("🛠 工具调用 (\(tools.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, t in
                            HStack(spacing: 6) {
                                Text("🛠 \(t.name)").font(.caption)
                                if let s = t.status {
                                    Text(s).font(.caption2).foregroundStyle(statusColor(s))
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .font(.caption2)
            }

            if !reasoning.isEmpty {
                DisclosureGroup("思考") {
                    MarkdownText(text: reasoning).font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "running": return .orange
        case "completed", "success": return .green
        case "error", "failed": return .red
        default: return .secondary
        }
    }
}
