import SwiftUI
import UIKit

private let bottomID = "bottom"

private struct TopYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ContentHKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ViewHKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, b in b }
    }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct ExpandableSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { isOpen.toggle() } label: {
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
    @State private var olderCursor: String?
    @State private var loadingOlder = false
    @State private var didInitialScroll = false
    @State private var showModels = false
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var topMinY: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private let pageSize = 25

    private var atBottom: Bool {
        guard viewportHeight > 0, contentHeight > 0 else { return true }
        let maxScroll = max(contentHeight - viewportHeight, 0)
        let scrolled = max(-topMinY, 0)
        return maxScroll - scrolled <= 150
    }

    private var session: Session? { store.session(sessionID) }
    private var permissions: [PendingPermission] { store.pendingPermissions.filter { $0.sessionID == sessionID } }
    private var questions: [PendingQuestion] { store.pendingQuestions.filter { $0.sessionID == sessionID } }
    private var forms: [FormInfo] { store.pendingForms.filter { $0.sessionID == sessionID } }
    private var isRunning: Bool { store.activeIDs.contains(sessionID) }
    private var queued: String? { store.queued[sessionID] }
    private var visibleMessages: [Message] { messages.filter { $0.type != "synthetic" } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView { timeline(proxy) }
                    .coordinateSpace(name: "scroll")
                    .scrollDismissesKeyboard(.immediately)
                    .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ViewHKey.self, value: g.size.height)
                    })
                    .onPreferenceChange(TopYKey.self) { topMinY = $0 }
                    .onPreferenceChange(ContentHKey.self) { contentHeight = $0 }
                    .onPreferenceChange(ViewHKey.self) { viewportHeight = $0 }
                    .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
                    .onPreferenceChange(TopYKey.self) { minY in
                        if didInitialScroll, minY > -60, olderCursor?.isEmpty == false, !loadingOlder {
                            Task { await loadOlder(proxy) }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                        if let id = bottomAnchorID() { reanchor(proxy, id) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                        if let id = bottomAnchorID() { reanchor(proxy, id) }
                    }
                    .onChange(of: messages.count) { _, _ in if atBottom { scrollToBottom(proxy) } }
                    .onChange(of: store.refreshTick) { _, _ in Task { await refreshNewest(); if atBottom { scrollToBottom(proxy) } } }
                    .task {
                        seedFromCache()
                        store.markViewed(sessionID)
                        if messages.isEmpty { await reload() } else { await refreshNewest() }
                        if !didInitialScroll {
                            for _ in 0..<8 {
                                scrollToBottom(proxy, animated: false)
                                try? await Task.sleep(nanoseconds: 80_000_000)
                                if didInitialScroll { break }
                            }
                            didInitialScroll = true
                        }
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            if Task.isCancelled { break }
                            // 仅在运行中兜底；空闲时靠 SSE 事件（refreshTick）驱动，避免空转请求。
                            if store.activeIDs.contains(sessionID) { await refreshNewest() }
                        }
                    }
            }
            ComposerView(sessionID: sessionID)
        }
        .navigationTitle(session?.displayTitle ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                modelMenu
                Button { Task { await store.interrupt(sessionID: sessionID) } } label: { Image(systemName: "stop.circle") }
                    .disabled(!isRunning)
            }
        }
        .sheet(isPresented: $showModels) {
            NavigationStack { ModelsView(sessionID: sessionID) }
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private func timeline(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            topSentinel
            if loadingOlder { loadingRow }
            header
            errorBanners
            messageList
            queuedBubble
            LiveStreamView(sessionID: sessionID, proxy: proxy, isAtBottom: { atBottom })
            pendingCards
            bottomSentinel
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear.preference(key: ContentHKey.self, value: g.size.height)
        })
    }

    private var topSentinel: some View {
        Color.clear
            .frame(height: 1)
            .background(GeometryReader { g in
                Color.clear.preference(key: TopYKey.self, value: g.frame(in: .named("scroll")).minY)
            })
    }

    private var bottomSentinel: some View {
        Color.clear.frame(height: 1).id(bottomID)
    }

    private var loadingRow: some View {
        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let err = store.sessionErrors[sessionID], !err.isEmpty {
            errorBanner(err)
        } else if session?.outcome == "failed" {
            errorBanner("上次执行失败（可继续对话重试）")
        }
        if let err = store.lastError, !err.isEmpty {
            Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.octagon")
            .font(.caption).foregroundStyle(.red)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var messageList: some View {
        ForEach(visibleMessages) { message in
            MessageRow(message: message)
                .id(message.id)
                .background(GeometryReader { g in
                    Color.clear.preference(key: RowFrameKey.self, value: [message.id: g.frame(in: .named("scroll"))])
                })
        }
    }

    @ViewBuilder
    private var queuedBubble: some View {
        if let q = queued, !q.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("你 · 发送中…").font(.caption2.bold()).foregroundStyle(.blue)
                Text(q)
            }
            .opacity(0.5)
            .id("queued")
        }
    }

    @ViewBuilder
    private var pendingCards: some View {
        ForEach(permissions) { PermissionCard(permission: $0) }
        ForEach(questions) { QuestionCard(question: $0) }
        ForEach(forms) { FormCard(form: $0) }
    }

    // MARK: - Scroll helpers

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) } }
        else { proxy.scrollTo(bottomID, anchor: .bottom) }
    }

    /// 视口内"最靠底部"的那条消息（= 输入框正上方那一行）的 id。
    private func bottomAnchorID() -> String? {
        let vh = viewportHeight > 0 ? viewportHeight : .greatestFiniteMagnitude
        let visible = rowFrames.filter { $0.value.maxY > 0 && $0.value.minY < vh }
        return visible.max { $0.value.minY < $1.value.minY }?.key
    }

    private func reanchor(_ proxy: ScrollViewProxy, _ id: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
        }
    }

    // MARK: - Data

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

    private func refreshNewest() async {
        let page = await store.loadMessages(sessionID: sessionID, limit: pageSize)
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in page.items { byId[m.id] = m }
        let merged = byId.values.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        if merged != messages { messages = merged; persist() }
        if olderCursor == nil, let prev = page.previous { olderCursor = prev; persist() }
        if let q = store.queued[sessionID],
           messages.contains(where: { $0.type == "user" && (($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == q) }) {
            store.queued[sessionID] = nil
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) async {
        guard didInitialScroll, !loadingOlder, let cursor = olderCursor, !cursor.isEmpty else { return }
        loadingOlder = true
        let anchor = messages.first?.id
        let page = await store.loadMessages(sessionID: sessionID, limit: pageSize, cursor: cursor)
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in page.items { byId[m.id] = m }
        messages = byId.values.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        olderCursor = page.previous
        persist()
        if let anchor {
            try? await Task.sleep(nanoseconds: 30_000_000)
            proxy.scrollTo(anchor, anchor: .top)
        }
        loadingOlder = false
    }

    // MARK: - Header / menus

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(isRunning ? Color.yellow : (store.sessionErrors[sessionID] != nil ? Color.red : Color.secondary.opacity(0.4))).frame(width: 9, height: 9)
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

    private var modelMenu: some View {
        Menu {
            ForEach(store.modelOptions.prefix(20), id: \.label) { model in
                Button(model.label) { Task { await store.switchModel(sessionID: sessionID, model: model) } }
            }
            Divider()
            Button("更多模型…") { showModels = true }
        } label: { Image(systemName: "cpu") }
    }
}

/// 只观察实时流式内容：token 更新时仅此子视图重绘，不会牵连历史消息与整个详情页。
private struct LiveStreamView: View {
    @Environment(PocketStore.self) private var store
    let sessionID: String
    let proxy: ScrollViewProxy
    let isAtBottom: () -> Bool

    private var live: String { store.liveText[sessionID] ?? "" }
    private var liveR: String { store.liveReasoning[sessionID] ?? "" }

    var body: some View {
        Group {
            if !live.isEmpty { LiveBubble(text: live).id("live") }
            if !liveR.isEmpty {
                ExpandableSection(title: "实时思考") {
                    MarkdownText(text: liveR).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: live) { _, _ in
            // 合流后每次写入最多触发一次；仅在贴底时跟随滚动。
            if isAtBottom() { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }
}

struct LiveBubble: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("实时", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2).foregroundStyle(.green)
            // 流式期间用纯文本渲染，避免逐 token 全量 Markdown 解析（O(n²)）。
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MessageRow: View {
    let message: Message

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

            if message.isUser {
                if let t = message.text, !t.isEmpty { MarkdownText(text: t).textSelection(.enabled) }
            } else {
                ForEach(Array((message.content ?? []).enumerated()), id: \.offset) { _, part in
                    partView(part)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func partView(_ part: Part) -> some View {
        switch part.type {
        case "reasoning":
            if let t = part.text, !t.isEmpty {
                ExpandableSection(title: "思考") {
                    MarkdownText(text: t).font(.caption).foregroundStyle(.secondary)
                }
            }
        case "text":
            if let t = part.text, !t.isEmpty { MarkdownText(text: t).textSelection(.enabled) }
        case "tool":
            if let name = part.name, !name.isEmpty {
                HStack(spacing: 6) {
                    Text("🛠 \(name)").font(.caption).foregroundStyle(.secondary)
                    if let s = part.state?.status { Text(s).font(.caption2).foregroundStyle(statusColor(s)) }
                }
            }
        default:
            EmptyView()
        }
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
