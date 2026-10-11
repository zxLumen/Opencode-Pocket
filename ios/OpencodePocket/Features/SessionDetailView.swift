import SwiftUI
import UIKit

private struct BottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
private struct TopYKey: PreferenceKey {
    static var defaultValue: CGFloat = -.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct ExpandableSection<Content: View>: View {
    let title: String
    let key: String
    @Binding var expanded: Set<String>
    @ViewBuilder var content: () -> Content
    private var isOpen: Bool { expanded.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isOpen { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2)
                    Text(title).font(.caption2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content() }
        }
    }
}

struct SessionDetailView: View {
    let sessionID: String
    @Environment(PocketStore.self) private var store
    @State private var messages: [Message] = []
    @State private var expanded: Set<String> = []
    @State private var olderCursor: String?
    @State private var loadingOlder = false
    @State private var follow = true
    @State private var viewportHeight: CGFloat = 0

    private let pageSize = 25

    private var session: Session? { store.session(sessionID) }
    private var permissions: [PendingPermission] { store.pendingPermissions.filter { $0.sessionID == sessionID } }
    private var questions: [PendingQuestion] { store.pendingQuestions.filter { $0.sessionID == sessionID } }
    private var forms: [FormInfo] { store.pendingForms.filter { $0.sessionID == sessionID } }
    private var isRunning: Bool { store.activeIDs.contains(sessionID) }
    private var live: String { store.liveText[sessionID] ?? "" }
    private var liveR: String { store.liveReasoning[sessionID] ?? "" }
    private var visibleMessages: [Message] { messages.filter { $0.type != "synthetic" } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // 非惰性 VStack：消息量有限（分页），避免 LazyVStack 在键盘/尺寸变化时不重排导致空白
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear
                            .frame(height: 1)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TopYKey.self, value: g.frame(in: .named("scroll")).minY)
                            })

                        if loadingOlder {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        }

                        header

                        if let err = store.lastError, !err.isEmpty {
                            Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        }

                        ForEach(visibleMessages) { message in
                            MessageRow(message: message, expanded: $expanded).id(message.id)
                        }

                        if !live.isEmpty { LiveBubble(text: live).id("live") }

                        if !liveR.isEmpty {
                            ExpandableSection(title: "实时思考", key: "live-r", expanded: $expanded) {
                                MarkdownText(text: liveR).font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        ForEach(permissions) { PermissionCard(permission: $0) }
                        ForEach(questions) { QuestionCard(question: $0) }
                        ForEach(forms) { FormCard(form: $0) }

                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomYKey.self, value: g.frame(in: .named("scroll")).minY)
                            })
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)     // 初始即在底部（原生，避免手动 scrollTo 的空白/错位）
                .coordinateSpace(name: "scroll")
                .scrollDismissesKeyboard(.interactively)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ViewHeightKey.self, value: g.size.height)
                })
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in follow = false })
                .onTapGesture { dismissKeyboard() }
                .onPreferenceChange(ViewHeightKey.self) { viewportHeight = $0 }
                .onPreferenceChange(BottomYKey.self) { minY in
                    if minY <= viewportHeight + 30 { follow = true }
                }
                .onPreferenceChange(TopYKey.self) { minY in
                    if minY > -60, olderCursor?.isEmpty == false, !loadingOlder {
                        Task { await loadOlder() }
                    }
                }
                .onChange(of: messages.count) { _, _ in if follow { scrollToBottom(proxy) } }
                .onChange(of: live) { _, _ in if follow { scrollToBottom(proxy) } }
                .onChange(of: store.refreshTick) { _, _ in
                    Task { await refreshNewest(); if follow { scrollToBottom(proxy) } }
                }
                .task(id: isRunning) {
                    seedFromCache()
                    store.markViewed(sessionID)
                    if messages.isEmpty {
                        await reload()
                        scrollToBottom(proxy, animated: false)
                    } else {
                        await refreshNewest()
                    }
                    while isRunning && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if Task.isCancelled { break }
                        await refreshNewest()
                        if follow { scrollToBottom(proxy) }
                    }
                }
            }

            ComposerView(sessionID: sessionID)
        }
        .navigationTitle(session?.displayTitle ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                agentMenu
                modelMenu
                Button { Task { await store.interrupt(sessionID: sessionID) } } label: { Image(systemName: "stop.circle") }
                    .disabled(!isRunning)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        else { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func seedFromCache() {
        guard messages.isEmpty, let cached = store.messageCache[sessionID], !cached.isEmpty else { return }
        messages = cached
        olderCursor = store.cursorCache[sessionID]
    }

    private func persist() {
        store.messageCache[sessionID] = messages
        if let c = olderCursor { store.cursorCache[sessionID] = c }
        else { store.cursorCache.removeValue(forKey: sessionID) }
    }

    private func reload() async {
        let page = await store.loadMessages(sessionID: sessionID, limit: pageSize)
        messages = page.items.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        olderCursor = page.previous
        persist()
    }

    /// 运行中只增量刷新最新一页，保留已加载的更早内容。
    private func refreshNewest() async {
        let page = await store.loadMessages(sessionID: sessionID, limit: pageSize)
        let newest = page.items.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        let existing = Set(messages.map { $0.id })
        let fresh = newest.filter { !existing.contains($0.id) }
        if !fresh.isEmpty {
            messages.append(contentsOf: fresh)
            persist()
        }
        if olderCursor == nil, let prev = page.previous { olderCursor = prev; persist() }
    }

    private func loadOlder() async {
        guard !loadingOlder, let cursor = olderCursor, !cursor.isEmpty else { return }
        loadingOlder = true
        let page = await store.loadMessages(sessionID: sessionID, limit: pageSize, cursor: cursor)
        let older = page.items.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        let existing = Set(messages.map { $0.id })
        messages = older.filter { !existing.contains($0.id) } + messages
        olderCursor = page.previous
        persist()
        loadingOlder = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(isRunning ? Color.yellow : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
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
    @Binding var expanded: Set<String>

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
                    Text("切换 Agent → \(message.agent ?? "?")").font(.caption2).foregroundStyle(.secondary)
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
                ExpandableSection(title: "🛠 工具调用 (\(tools.count))", key: "tools:\(message.id)", expanded: $expanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, t in
                            HStack(spacing: 6) {
                                Text("🛠 \(t.name)").font(.caption)
                                if let s = t.status { Text(s).font(.caption2).foregroundStyle(statusColor(s)) }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if !reasoning.isEmpty {
                ExpandableSection(title: "思考", key: "reason:\(message.id)", expanded: $expanded) {
                    MarkdownText(text: reasoning).font(.caption).foregroundStyle(.secondary)
                }
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
