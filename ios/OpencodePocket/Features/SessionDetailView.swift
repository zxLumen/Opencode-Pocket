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
/// 底部哨兵在滚动坐标系里的位置——用来直接量「上拉过卷了多少」。
private struct BottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private enum PullPhase: Equatable { case idle, armed, refreshing, done }

/// 行位置与滚动度量的盒子：刻意**不**做成 @State，写它不会触发重渲染，
/// 从而避免「偏好 → state → 重渲染 → 新偏好」的每帧回环。
/// 这些值只在事件回调里被读取（判定贴底 / 键盘重锚 / 上拉过卷），不需要驱动 UI。
private final class FrameBox {
    var frames: [String: CGRect] = [:]
    var topMinY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var bottomMinY: CGFloat = .greatestFiniteMagnitude
    var viewportHeight: CGFloat = 0
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
    @State private var frames = FrameBox()
    @State private var pullPhase: PullPhase = .idle
    @State private var refreshCount = 0
    @State private var lastRefreshAt: Date?

    private let pageSize = 50       // 首次加载（最近 50 条）
    private let olderBatch = 25     // 上拉到顶时每批再取
    private let windowMax = 150     // 内存 / 渲染窗口上限

    /// 是否贴底。**绝不能因为"量不到"就判定贴底**，否则会在你阅读中途
    /// 被周期性刷新强行拽到底部。这里两个信号同时成立才算贴底，未知一律按"没贴底"。
    private var atBottom: Bool {
        guard frames.viewportHeight > 0 else { return true }   // 尚未测量（首帧）
        // 底部哨兵被 LazyVStack 回收时拿不到值 → 说明离底部很远
        guard frames.bottomMinY < .greatestFiniteMagnitude else { return false }
        let sentinelSaysBottom = frames.bottomMinY <= frames.viewportHeight + 120
        // 粗筛：只看"是否明显离底部很远"，防止哨兵值变陈旧而误判
        var offsetSaysNotFar = true
        if frames.contentHeight > 0 {
            let maxScroll = max(frames.contentHeight - frames.viewportHeight, 0)
            offsetSaysNotFar = (maxScroll - max(-frames.topMinY, 0)) <= 200
        }
        return sentinelSaysBottom && offsetSaysNotFar
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
                    .onPreferenceChange(ViewHKey.self) { frames.viewportHeight = $0 }
                    .onPreferenceChange(TopYKey.self) { frames.topMinY = $0 }
                    .onPreferenceChange(ContentHKey.self) { frames.contentHeight = $0 }
                    .onPreferenceChange(RowFrameKey.self) { frames.frames = $0 }
                    .onPreferenceChange(BottomYKey.self) { v in
                        frames.bottomMinY = v
                        pullEvaluate()
                    }
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
                    .onChange(of: store.refreshTick) { _, _ in
                        // 刷新前先记录是否贴底：避免 await 期间位置变化导致误滚
                        let wasAtBottom = atBottom
                        Task { await refreshNewest(); if wasAtBottom, atBottom { scrollToBottom(proxy) } }
                    }
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
                            // 运行中刷得勤一点，空闲也保持低频刷新：
                            // 否则会话一旦变 idle/failed，详情页就永远停在报错/收尾前那一帧。
                            let iv: UInt64 = store.activeIDs.contains(sessionID) ? 4_000_000_000 : 10_000_000_000
                            try? await Task.sleep(nanoseconds: iv)
                            if Task.isCancelled { break }
                            await refreshNewest()
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
        LazyVStack(alignment: .leading, spacing: 14) {
            topSentinel
            if loadingOlder { loadingRow }
            header
            errorBanners
            messageList
            queuedBubble
            LiveStreamView(sessionID: sessionID, proxy: proxy, isAtBottom: { atBottom })
            pendingCards
            pullFooter
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
        Color.clear
            .frame(height: 1)
            .id(bottomID)
            .background(GeometryReader { g in
                Color.clear.preference(key: BottomYKey.self, value: g.frame(in: .named("scroll")).minY)
            })
    }

    /// 底部提示条：上拉刷新（点一下也能刷新）。
    @ViewBuilder
    private var pullFooter: some View {
        Button { beginPullRefresh() } label: {
            HStack(spacing: 6) {
                switch pullPhase {
                case .idle:
                    Image(systemName: "arrow.up")
                    Text("上拉刷新")
                case .armed:
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                    Text("松开刷新")
                case .refreshing:
                    ProgressView().controlSize(.small)
                    Text("刷新中…")
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                    Text(doneLabel)
                }
            }
            .font(.caption2)
            .foregroundStyle(pullPhase == .armed ? Color.accentColor
                             : (pullPhase == .done ? Color.green : Color.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var doneLabel: String {
        var s = "已刷新 ×\(refreshCount)"
        if let d = lastRefreshAt {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            s += " · \(f.string(from: d))"
        }
        return s
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
                .equatable()
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

    /// 底部过卷（上拉）超出阈值就触发刷新。
    /// 直接量底部哨兵被推出视口多少：过卷量 = viewportHeight - 哨兵.minY。
    private func pullEvaluate() {
        guard didInitialScroll, frames.viewportHeight > 0, pullPhase != .refreshing else { return }
        let overscroll = frames.viewportHeight - frames.bottomMinY
        switch pullPhase {
        case .idle:
            if overscroll >= 40 {
                pullPhase = .armed
                print("[pull] armed overscroll=\(Int(overscroll))")
            }
        case .armed:
            if overscroll < 24 {
                pullPhase = .idle
            } else if overscroll >= 58 {
                beginPullRefresh()
            }
        case .done:
            if overscroll < 10 { pullPhase = .idle }
        case .refreshing:
            break
        }
    }

    /// 执行一次刷新：转圈（最短 1.2s）→ 显示「已刷新 ×N · 时间」→ 回到上箭头。
    private func beginPullRefresh() {
        guard pullPhase != .refreshing else { return }
        pullPhase = .refreshing
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let started = Date()
        Task {
            let before = messages.count
            await refreshNewest()
            print("[pull] refresh done \(before) -> \(messages.count) 条")
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 1.2 {
                try? await Task.sleep(nanoseconds: UInt64((1.2 - elapsed) * 1_000_000_000))
            }
            if Task.isCancelled { return }
            refreshCount += 1
            lastRefreshAt = Date()
            pullPhase = .done
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            if pullPhase == .done { pullPhase = .idle }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) } }
        else { proxy.scrollTo(bottomID, anchor: .bottom) }
    }

    /// 视口内"最靠底部"的那条消息（= 输入框正上方那一行）的 id。
    private func bottomAnchorID() -> String? {
        let vh = frames.viewportHeight > 0 ? frames.viewportHeight : .greatestFiniteMagnitude
        let visible = frames.frames.filter { $0.value.maxY > 0 && $0.value.minY < vh }
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
        if messages.count > windowMax { messages = Array(messages.suffix(windowMax)) }
        olderCursor = page.previous
        persist()
    }

    /// 拉最新一页。
    /// - 贴底时：并入新消息，并从**最老端**裁到窗口上限（正常"看最新"场景）。
    /// - 不在底部时：只**更新已有消息**（流式内容等），不并入新消息，
    ///   也不裁老消息——否则你上翻看历史时窗口会被顶得来回抖动、跳位。
    private func refreshNewest() async {
        let page = await store.loadMessages(sessionID: sessionID, limit: pageSize)
        let bottom = atBottom
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if bottom {
            for m in page.items { byId[m.id] = m }
        } else {
            for m in page.items where byId[m.id] != nil { byId[m.id] = m }
        }
        var merged = byId.values.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        if bottom, merged.count > windowMax { merged = Array(merged.suffix(windowMax)) }
        if merged != messages { messages = merged; persist() }
        if olderCursor == nil, let prev = page.previous { olderCursor = prev; persist() }
        if let q = store.queued[sessionID],
           messages.contains(where: { $0.type == "user" && (($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == q) }) {
            store.queued[sessionID] = nil
        }
    }

    /// 上拉到顶：再取一批更早的；超过窗口上限就从**最新端**裁（因为你正在往回看）。
    private func loadOlder(_ proxy: ScrollViewProxy) async {
        guard didInitialScroll, !loadingOlder, let cursor = olderCursor, !cursor.isEmpty else { return }
        loadingOlder = true
        let anchor = messages.first?.id
        let page = await store.loadMessages(sessionID: sessionID, limit: olderBatch, cursor: cursor)
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in page.items { byId[m.id] = m }
        var merged = byId.values.sorted { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        if merged.count > windowMax { merged = Array(merged.prefix(windowMax)) }
        messages = merged
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

struct MessageRow: View, Equatable {
    let message: Message

    /// 只有消息本身变化时才重建（长列表里能省下大量 diff/渲染）。
    static func == (a: MessageRow, b: MessageRow) -> Bool { a.message == b.message }

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
                if let failure = message.failureText {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.octagon.fill")
                        Text(failure).multilineTextAlignment(.leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
