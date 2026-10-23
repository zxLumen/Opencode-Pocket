import Foundation
import Observation

struct ServerInfo: Codable, Sendable {
    var version: String?
    var pid: Int?
    var urls: [String]?
}

struct ActiveStatus: Codable, Sendable { var type: String? }

enum DotState { case pending, running, failed, done, idle }

/// 轻量本地持久化（收藏 / 已读时间）。
enum Prefs {
    static var favorites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "opencode.pocket.favs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "opencode.pocket.favs") }
    }
    static var viewed: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: "opencode.pocket.viewed") as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "opencode.pocket.viewed") }
    }
    static var favoriteModels: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "opencode.pocket.favModels") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "opencode.pocket.favModels") }
    }
    /// 上次执行失败的原因（按 sessionID）。持久化后，重启 App 也能看到为什么失败。
    static var sessionErrors: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "opencode.pocket.sessErrors") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "opencode.pocket.sessErrors") }
    }
}

struct MessagesResponse: Decodable {
    var data: [Message]
    var cursor: Cursor?
    struct Cursor: Decodable { var previous: String?; var next: String? }
}

/// 一次消息拉取的结果。`ok == false` 表示这次没拿到数据（失败或被取消），
/// 调用方必须保留现有消息，绝不能用空数组覆盖缓存。
struct MessagePage: Sendable {
    var items: [Message]
    var older: String?
    var ok: Bool
}

private struct PermissionItemDTO: Decodable {
    var id: String
    var sessionID: String?
    var action: String?
    var resources: [String]?
    var message: String?
}
private struct QuestionItemDTO: Decodable {
    var id: String
    var sessionID: String?
    var questions: [QuestionInfo]?
}

@MainActor
@Observable
final class PocketStore {
    enum Phase: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    var phase: Phase = .disconnected
    var sessions: [Session] = []
    var activeIDs: Set<String> = []
    var agents: [Agent] = []
    var pendingPermissions: [PendingPermission] = []
    var pendingQuestions: [PendingQuestion] = []
    var pendingForms: [FormInfo] = []
    var liveText: [String: String] = [:]
    var liveReasoning: [String: String] = [:]
    var sessionErrors: [String: String] = Prefs.sessionErrors {
        didSet {
            // 防止无限增长：只保留最近 80 条
            if sessionErrors.count > 80 {
                let keep = Set(sessionErrors.sorted { $0.key < $1.key }.suffix(80).map(\.key))
                sessionErrors = sessionErrors.filter { keep.contains($0.key) }
            }
            Prefs.sessionErrors = sessionErrors
        }
    }
    var lastError: String?
    var serverVersion: String?
    var offline = false
    var refreshTick = 0

    // 收藏 / 已读 / 消息缓存
    var favorites: Set<String> = Prefs.favorites
    var lastViewedAt: [String: Double] = Prefs.viewed
    var messageCache: [String: [Message]] = [:]
    var cursorCache: [String: String] = [:]
    var availableModels: [ModelRef] = []
    var integrations: [Integration] = []
    var favoriteModels: Set<String> = Prefs.favoriteModels
    var drafts: [String: String] = [:]
    var queued: [String: String] = [:]
    var defaultModelLabel: String = UserDefaults.standard.string(forKey: "opencode.pocket.defaultModel") ?? "" {
        didSet { UserDefaults.standard.set(defaultModelLabel, forKey: "opencode.pocket.defaultModel") }
    }

    // Connection form fields
    static let defaultServerURL = "https://pocket.example.com"
    var baseURL: String = Credentials.baseURL.isEmpty ? PocketStore.defaultServerURL : Credentials.baseURL
    var username: String = Credentials.username
    var password: String = ""

    // Navigation
    var deepLinkSessionID: String?

    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pollTick = 0
    private var eventsConnected = false

    /// 流式增量缓冲：合流后（~80ms）再写入 liveText/liveReasoning，
    /// 避免每个 token 都触发 SwiftUI 整页重绘。
    private var liveBuf: [String: (text: String, reasoning: String)] = [:]

    // MARK: - Connection

    func client() throws -> APIClient {
        try APIClient(baseURL: baseURL, username: username, password: Credentials.password)
    }

    func connect() async {
        guard phase != .connecting else { return }
        phase = .connecting
        lastError = nil
        if !password.isEmpty { Credentials.password = password }
        do {
            let c = try client()
            let info = try await c.getData("/api/info", as: ServerInfo.self)
            serverVersion = info.version
            Credentials.baseURL = baseURL
            Credentials.username = username
            phase = .connected
            offline = false
            reconnectTask?.cancel(); reconnectTask = nil
            await refreshAll()
            startEvents()
            startPolling()
        } catch {
            // 切后台 / 页面被移除时 URLSession 会取消请求（-999 cancelled）。
            // 这不是连接失败：保持「未连接」，回到前台时会自动重连。
            if Self.isCancellation(error) {
                phase = .disconnected
                return
            }
            let msg = Self.friendly(error)
            phase = .failed(msg)
            lastError = msg
        }
    }

    // MARK: - 离线判定 / 自动重连

    private static func isNetwork(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// 请求被取消不是错误：视图消失、App 切后台、或者上游主动取消都会让
    /// URLSession 抛 `URLError.cancelled`（NSURLErrorDomain -999）。
    /// 以前它被当成「消息解析失败」弹成一大段红字，还会让详情页以为这一页是空的。
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    static func friendly(_ error: Error) -> String {
        if isCancellation(error) { return "请求已取消" }
        if isNetwork(error) { return "连接中断：Mac 可能已休眠/离线，或网络不可用。正在自动重连…" }
        return error.localizedDescription
    }

    /// 把服务端报的失败原因翻成人话，并附上可操作建议。
    static func friendlyFailure(_ raw: String?) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "执行失败（服务端未返回原因）" }
        let l = s.lowercased()
        if l.contains("rate limit") || l.contains("too many request") || s.contains("限流") || s.contains("配额") || l.contains("quota") {
            return "模型限流（Rate limit），稍后重试或换个模型：\(s)"
        }
        if l.contains("unauthorized") || l.contains("401") || l.contains("api key") {
            return "模型鉴权失败，去「提供商」重新连接 API Key：\(s)"
        }
        return s
    }

    private func markOfflineIfNetwork(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        if Self.isNetwork(error) {
            offline = true
            eventsConnected = false
            startReconnect()
        }
    }

    private func startReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if let c = try? self.client(),
                   (try? await c.getData("/api/info", as: ServerInfo.self)) != nil {
                    self.offline = false
                    self.lastError = nil
                    self.startEvents()
                    self.startPolling()
                    await self.refreshAll()
                    self.reconnectTask = nil
                    return
                }
            }
        }
    }

    func disconnect() {
        suspend()
        phase = .disconnected
    }

    /// 进入后台：停止 SSE / 轮询 / 重连 / 合流，避免后台空转与回前台重连风暴。
    func suspend() {
        eventTask?.cancel(); eventTask = nil
        pollTask?.cancel(); pollTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        flushTask?.cancel(); flushTask = nil
        eventsConnected = false
    }

    /// 回到前台：已连接则恢复 SSE / 轮询并刷新；未连接则尝试重连。
    func handleBecameActive() async {
        guard Credentials.isConfigured else { return }
        switch phase {
        case .connected:
            startEvents()
            startPolling()
            await refreshAll()
            refreshTick += 1      // 回前台后让打开着的会话详情立即重拉消息
        case .disconnected:
            await connect()
        default:
            break
        }
    }

    // MARK: - Loading

    func refreshAll() async {
        async let a: Void = loadSessions()
        async let b: Void = loadAgents()
        async let c: Void = loadPending()
        async let d: Void = loadModels()
        async let e: Void = loadIntegrations()
        async let f: Void = loadActive()
        _ = await (a, b, c, d, e, f)
    }

    func loadModels() async {
        guard let c = try? client() else { return }
        if let list = try? await c.getData("/api/model", as: [ModelDTO].self) {
            availableModels = list.map { $0.ref }
        }
    }

    func loadIntegrations() async {
        guard let c = try? client() else { return }
        if let list = try? await c.getData("/api/integration", as: [Integration].self) {
            integrations = list
        }
    }

    /// 用 API Key 连接一个 provider。
    @discardableResult
    func connectKey(integrationID: String, key: String, label: String?) async -> Bool {
        guard let c = try? client(), !key.isEmpty else { return false }
        var body: [String: Any] = ["key": key]
        if let label, !label.isEmpty { body["label"] = label }
        do {
            try await c.postJSON("/api/integration/\(integrationID)/connect/key", json: body)
            await loadIntegrations()
            await loadModels()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func isFavoriteModel(_ m: ModelRef) -> Bool { favoriteModels.contains(m.label) }

    func toggleFavoriteModel(_ m: ModelRef) {
        if favoriteModels.contains(m.label) { favoriteModels.remove(m.label) } else { favoriteModels.insert(m.label) }
        Prefs.favoriteModels = favoriteModels
    }

    func setDefaultModel(_ m: ModelRef) async {
        defaultModelLabel = m.label
        guard let c = try? client() else { return }
        try? await c.request("/api/config", method: "PATCH", json: ["model": m.label])
    }

    /// 可选模型：优先服务器返回的列表，回退到现有会话里用过的；收藏置顶、按名排序。
    var modelOptions: [ModelRef] {
        let base = availableModels.isEmpty ? distinctModels : availableModels
        var seen = Set<String>()
        var out: [ModelRef] = []
        for m in base where !seen.contains(m.label) { seen.insert(m.label); out.append(m) }
        return out.sorted { a, b in
            let fa = favoriteModels.contains(a.label), fb = favoriteModels.contains(b.label)
            if fa != fb { return fa }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    func loadSessions() async {
        guard let c = try? client() else { return }
        do {
            sessions = try await c.getData("/api/session", as: [Session].self)
            // 首次见到的会话基准为「已读」，避免一打开全变绿
            var changed = false
            for s in sessions where lastViewedAt[s.id] == nil {
                lastViewedAt[s.id] = s.time?.updated ?? 0
                changed = true
            }
            if changed { Prefs.viewed = lastViewedAt }
            offline = false
        } catch { markOfflineIfNetwork(error) }
    }

    func loadActive() async {
        guard let c = try? client() else { return }
        do {
            let map = try await c.getData("/api/session/active", as: [String: ActiveStatus].self)
            activeIDs = Set(map.compactMap { $0.value.type == "running" ? $0.key : nil })
            offline = false
            refreshTick += 1          // 兜底轮询也驱动详情页刷新（SSE 断流时仍能更新）
        } catch { markOfflineIfNetwork(error) }
    }

    func loadAgents() async {
        guard let c = try? client() else { return }
        do { agents = try await c.getData("/api/agent", as: [Agent].self) } catch { /* ignore */ }
    }

    func loadPending() async {
        guard let c = try? client() else { return }
        // 审批/表单都是按 location（目录）作用域的；服务器默认 location 是自身 cwd，
        // 因此要针对各会话所在目录逐个查询并合并。
        var dirs = Set(sessions.compactMap { $0.directory })
        dirs.insert("")  // 空 = 默认 location

        var perms: [String: PendingPermission] = [:]
        var forms: [String: FormInfo] = [:]

        for dir in dirs {
            let q = dir.isEmpty ? [] : [URLQueryItem(name: "location[directory]", value: dir)]

            if let raw = try? await c.getRawJSON("/api/permission/request", query: q) {
                for item in Self.array(from: raw) {
                    if let dto = try? JSONDecoder().decode(PermissionItemDTO.self, from: JSONSerialization.data(withJSONObject: item)) {
                        perms[dto.id] = PendingPermission(id: dto.id, sessionID: dto.sessionID, action: dto.action,
                                                          resources: dto.resources ?? [],
                                                          title: dto.message ?? Self.permissionTitle(dto), createdAt: nil)
                    }
                }
            }
            if let list = try? await c.getData("/api/form", query: q, as: [FormInfo].self) {
                for f in list { forms[f.id] = f }
            }
        }

        pendingPermissions = Array(perms.values)
        pendingForms = Array(forms.values)
        pendingQuestions = []
    }

    /// 拉取一页消息（默认最新 N 条，倒序返回），并给出更早一页的 cursor。
    /// 失败或被取消时 `ok == false`，调用方必须保留已有消息/游标。
    func loadMessages(sessionID: String, limit: Int = 25, cursor: String? = nil) async -> MessagePage {
        guard let c = try? client() else { return MessagePage(items: [], older: nil, ok: false) }
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        // opencode 规定 cursor 不能和 order 一起传（否则 400 InvalidCursorError）。
        // 第一页用 desc 拿最新 N 条；翻更早的页时只带 cursor。
        if let cursor, !cursor.isEmpty {
            q.append(URLQueryItem(name: "cursor", value: cursor))
        } else {
            q.append(URLQueryItem(name: "order", value: "desc"))
        }
        do {
            let r = try await fetchMessages(with: c, sessionID: sessionID, query: q)
            if lastError?.hasPrefix("消息") == true { lastError = nil }
            return MessagePage(items: r.data, older: r.cursor?.next, ok: true)
        } catch {
            // 取消是正常生命周期（离开页面 / 切后台），既不报错也不标记离线；
            // 下一轮刷新会重新拉取。
            if Self.isCancellation(error) {
                return MessagePage(items: [], older: nil, ok: false)
            }
            markOfflineIfNetwork(error)
            // 解码失败绝不能静默：否则详情页会「卡住不动」，
            // 表现为报错/新内容永远刷不出来（历史上踩过一次）。
            if !Self.isNetwork(error) {
                if let api = error as? APIError, case .decode(let detail) = api {
                    lastError = "消息解析失败：\(detail)"
                } else {
                    lastError = "消息加载失败：\(error.localizedDescription)"
                }
            }
            return MessagePage(items: [], older: nil, ok: false)
        }
    }

    /// 优先走 pocketd 的 `/messages` 中继：它会丢掉 tool.state.input/output 等
    /// 超大字段（实测一页 50 条从 6.4MB 降到 64KB），手机端轮询才不会超时/被取消。
    /// 连的是没有 pocketd 的裸 opencode（或旧版 pocketd）时，回退到官方接口。
    private func fetchMessages(with c: APIClient, sessionID: String,
                               query: [URLQueryItem]) async throws -> MessagesResponse {
        do {
            var q = [URLQueryItem(name: "session", value: sessionID)]
            q.append(contentsOf: query)
            return try await c.getData("/pocketd/messages", query: q, as: MessagesResponse.self)
        } catch let api as APIError {
            guard case .status(let code, _) = api,
                  [404, 405, 501, 502].contains(code) else { throw api }
            return try await c.getData("/api/session/\(sessionID)/message", query: query, as: MessagesResponse.self)
        }
    }

    // MARK: - Events

    private func startEvents() {
        eventTask?.cancel()
        guard let c = try? client() else { return }
        let base = c.base
        let auth = c.authorization
        eventTask = Task { [weak self] in
            for await event in EventStream.connect(base: base, authorization: auth) {
                self?.handle(event)
            }
        }
    }

    /// 周期性刷新活动会话与列表（事件之外的安全网，做到"无需手动刷新"）。
    private func startPolling() {
        pollTask?.cancel()
        pollTick = 0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                // SSE 正常时大幅降频（仅作安全网）；断流时稍快兜底。
                let interval: UInt64 = self.eventsConnected ? 30_000_000_000 : 10_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self.loadActive()
                self.pollTick += 1
                if self.pollTick % 3 == 0 {
                    await self.loadSessions()
                    await self.loadPending()
                }
            }
        }
    }

    /// 最多约每 80ms 把流式缓冲写入 liveText/liveReasoning 一次。
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self else { return }
            self.flushLive()
            self.flushTask = nil
        }
    }

    private func flushLive() {
        guard !liveBuf.isEmpty else { return }
        for (sid, buf) in liveBuf {
            if !buf.text.isEmpty { liveText[sid, default: ""] += buf.text }
            if !buf.reasoning.isEmpty { liveReasoning[sid, default: ""] += buf.reasoning }
        }
        liveBuf.removeAll(keepingCapacity: true)
    }

    private func handle(_ event: OpenCodeEvent) {
        eventsConnected = true
        let type = event.type
        let sid = event.sessionID

        // 流式增量（回答 / 思考）：先进缓冲区，合流后再写入，避免逐 token 重绘
        if type.contains("delta"), let sid {
            let d = event.delta ?? event.text ?? ""
            if !d.isEmpty {
                if type.contains("reasoning") { liveBuf[sid, default: (text: "", reasoning: "")].reasoning += d }
                else { liveBuf[sid, default: (text: "", reasoning: "")].text += d }
                scheduleFlush()
            }
            return
        }

        if type.contains("permission") || type.contains("question") {
            Task { await loadPending() }
            return
        }

        // 执行失败 / 出错：记录错误，供会话内红字提示
        if type.contains("execution.failed") || type.contains("step.failed") || type == "session.error" {
            if let sid { sessionErrors[sid] = Self.friendlyFailure(event.errorMessage) }
        }

        guard type.hasPrefix("session.") || type.hasPrefix("message.") else { return }
        switch type {
        case "session.idle", "session.execution.succeeded", "session.execution.failed":
            flushLive()
            if let sid {
                activeIDs.remove(sid)
                liveBuf[sid] = nil
                liveText[sid] = ""
                liveReasoning[sid] = ""
            }
            refreshTick += 1
            Task { await loadSessions(); await loadPending() }
            // 抵消「事件先到、消息后落库」的竞态：稍后再催两次刷新，
            // 确保失败原因 / 收尾内容被拉取到（否则详情页会永远停在报错前一帧）。
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self else { return }
                await self.loadSessions()
                self.refreshTick += 1
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.refreshTick += 1
            }
        case "session.execution.started", "session.step.started":
            if let sid { activeIDs.insert(sid); sessionErrors[sid] = nil }
            Task { await loadActive() }
        case "session.created", "session.updated", "session.deleted", "session.status":
            Task { await loadSessions() }
        default:
            break
        }
    }

    // MARK: - Actions

    func sendPrompt(sessionID: String, text: String, attachments: [Attachment] = []) async {
        guard let c = try? client() else { return }
        // 允许空文本/空附件：ComposerView 会把纯空白输入转成「继续」；服务端也接受空 text。
        do {
            var body: [String: Any] = ["text": text]
            if !attachments.isEmpty {
                body["files"] = attachments.map { ["uri": $0.uri, "name": $0.name] }
            }
            try await c.postJSON("/api/session/\(sessionID)/prompt", json: body)
            sessionErrors[sessionID] = nil   // 新的指令，清掉上次错误
            queued[sessionID] = text.isEmpty ? "继续" : text   // 乐观：立即显示"发送中"
            refreshTick += 1
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 上传图片到 Mac（经 /pocketd/upload），返回可附带的 Attachment。
    func uploadImage(_ data: Data, contentType: String, name: String) async -> Attachment? {
        guard let c = try? client() else { return nil }
        do {
            let r = try await c.upload(data, contentType: contentType, name: name)
            return Attachment(uri: r.uri, name: r.name, data: data)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func interrupt(sessionID: String) async {
        guard let c = try? client() else { return }
        do { try await c.postJSON("/api/session/\(sessionID)/interrupt") }
        catch { lastError = error.localizedDescription }
        activeIDs.remove(sessionID)
    }

    // MARK: - 新建会话

    var knownDirectories: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in sessions {
            if let d = s.directory, !d.isEmpty, !seen.contains(d) { seen.insert(d); out.append(d) }
        }
        return out
    }

    var suggestedModel: ModelRef? {
        var counts: [String: (ModelRef, Int)] = [:]
        for s in sessions {
            guard let m = s.model else { continue }
            counts[m.label] = (m, (counts[m.label]?.1 ?? 0) + 1)
        }
        return counts.values.max { $0.1 < $1.1 }?.0
    }

    func createSession(directory: String, agent: String?, model: ModelRef?) async -> String? {
        guard let c = try? client(), !directory.isEmpty else { return nil }
        var body: [String: Any] = ["location": ["directory": directory]]
        if let agent, !agent.isEmpty { body["agent"] = agent }
        if let model {
            var m: [String: Any] = ["id": model.id, "providerID": model.providerID]
            if let v = model.variant { m["variant"] = v }
            body["model"] = m
        }
        do {
            let data = try await c.request("/api/session", method: "POST", json: body)
            let obj = try JSONSerialization.jsonObject(with: data)
            let dict = obj as? [String: Any]
            let id = ((dict?["data"] as? [String: Any])?["id"] as? String) ?? (dict?["id"] as? String)
            await loadSessions()
            return id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func replyPermission(_ p: PendingPermission, reply: String) async {
        guard let c = try? client(), let sid = p.sessionID else { return }
        pendingPermissions.removeAll { $0.id == p.id }   // 乐观移除
        do {
            try await c.postJSON("/api/session/\(sid)/permission/\(p.id)/reply", json: ["decision": reply])
        } catch { lastError = error.localizedDescription }
        await loadPending()
    }

    func replyQuestion(_ q: PendingQuestion, answers: [[String]]) async {
        guard let c = try? client(), let sid = q.sessionID else { return }
        pendingQuestions.removeAll { $0.id == q.id }   // 乐观移除
        do {
            try await c.postJSON("/api/session/\(sid)/question/\(q.id)/reply", json: ["answers": answers])
        } catch { lastError = error.localizedDescription }
        await loadPending()
    }

    func rejectQuestion(_ q: PendingQuestion) async {
        guard let c = try? client(), let sid = q.sessionID else { return }
        pendingQuestions.removeAll { $0.id == q.id }   // 乐观移除
        do {
            try await c.postJSON("/api/session/\(sid)/question/\(q.id)/reject")
        } catch { lastError = error.localizedDescription }
        await loadPending()
    }

    func replyForm(_ form: FormInfo, answer: [String: Any]) async {
        guard let c = try? client() else { return }
        pendingForms.removeAll { $0.id == form.id }   // 乐观移除，避免卡片滞留
        do {
            try await c.postJSON("/api/session/\(form.sessionID)/form/\(form.id)/reply", json: ["answer": answer])
        } catch { lastError = error.localizedDescription }
        await loadPending()
    }

    func switchAgent(sessionID: String, agent: String) async {
        guard let c = try? client() else { return }
        do {
            try await c.postJSON("/api/session/\(sessionID)/agent", json: ["agent": agent])
            await loadSessions()
        } catch { lastError = error.localizedDescription }
    }

    func switchModel(sessionID: String, model: ModelRef) async {
        guard let c = try? client() else { return }
        do {
            var body: [String: Any] = ["id": model.id, "providerID": model.providerID]
            if let v = model.variant { body["variant"] = v }
            try await c.postJSON("/api/session/\(sessionID)/model", json: ["model": body])
            await loadSessions()
        } catch { lastError = error.localizedDescription }
    }

    // MARK: - Deep link

    func handleDeepLink(_ url: URL) {
        // opencodepocket://session/<id>
        guard url.scheme == "opencodepocket" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "session", let id = parts.first { deepLinkSessionID = id }
        else if let id = parts.first { deepLinkSessionID = id }
    }

    // MARK: - Helpers

    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    func pendingCount(for sessionID: String) -> Int {
        pendingPermissions.filter { $0.sessionID == sessionID }.count
            + pendingQuestions.filter { $0.sessionID == sessionID }.count
            + pendingForms.filter { $0.sessionID == sessionID }.count
    }

    // MARK: - 收藏 / 已读 / 状态圆点

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        Prefs.favorites = favorites
    }

    func markViewed(_ id: String) {
        lastViewedAt[id] = Date().timeIntervalSince1970 * 1000
        Prefs.viewed = lastViewedAt
    }

    func isUnread(_ s: Session) -> Bool {
        (s.time?.updated ?? 0) > (lastViewedAt[s.id] ?? 0)
    }

    /// 优先级：待办 > 运行中 > 失败 > 未读完成 > 已读
    func dotState(for s: Session) -> DotState {
        if pendingCount(for: s.id) > 0 { return .pending }
        if activeIDs.contains(s.id) { return .running }
        if sessionErrors[s.id] != nil || s.outcome == "failed" { return .failed }
        if isUnread(s) { return .done }
        return .idle
    }

    var distinctModels: [ModelRef] {
        var seen = Set<String>()
        var out: [ModelRef] = []
        for s in sessions {
            if let m = s.model, !seen.contains(m.label) { seen.insert(m.label); out.append(m) }
        }
        return out
    }

    private static func array(from raw: Any) -> [[String: Any]] {
        if let arr = raw as? [[String: Any]] { return arr }
        if let dict = raw as? [String: Any], let data = dict["data"] as? [[String: Any]] { return data }
        if let dict = raw as? [String: Any], let data = dict["data"] as? [String: Any] { return [data] }
        return []
    }

    private static func permissionTitle(_ dto: PermissionItemDTO) -> String {
        if let a = dto.action, !a.isEmpty {
            let res = dto.resources?.first
            return res.map { "\(a): \($0)" } ?? a
        }
        return "权限请求"
    }
}
