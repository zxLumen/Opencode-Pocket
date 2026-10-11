import Foundation
import Observation

struct ServerInfo: Codable, Sendable {
    var version: String?
    var pid: Int?
    var urls: [String]?
}

struct ActiveStatus: Codable, Sendable { var type: String? }

private struct PermissionItemDTO: Decodable {
    var id: String
    var sessionID: String?
    var action: String?
    var resources: [String]?
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
    var liveText: [String: String] = [:]
    var lastError: String?
    var serverVersion: String?

    // Connection form fields
    var baseURL: String = Credentials.baseURL
    var username: String = Credentials.username
    var password: String = ""

    // Navigation
    var deepLinkSessionID: String?

    private var eventTask: Task<Void, Never>?

    // MARK: - Connection

    func client() throws -> APIClient {
        try APIClient(baseURL: baseURL, username: username, password: Credentials.password)
    }

    func connect() async {
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
            await refreshAll()
            startEvents()
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        phase = .disconnected
    }

    // MARK: - Loading

    func refreshAll() async {
        async let a: Void = loadSessions()
        async let b: Void = loadAgents()
        async let c: Void = loadPending()
        _ = await (a, b, c)
    }

    func loadSessions() async {
        guard let c = try? client() else { return }
        do {
            sessions = try await c.getData("/api/session", as: [Session].self)
        } catch { lastError = error.localizedDescription }
        await loadActive()
    }

    func loadActive() async {
        guard let c = try? client() else { return }
        do {
            let map = try await c.getData("/api/session/active", as: [String: ActiveStatus].self)
            activeIDs = Set(map.compactMap { $0.value.type == "running" ? $0.key : nil })
        } catch { /* ignore */ }
    }

    func loadAgents() async {
        guard let c = try? client() else { return }
        do { agents = try await c.getData("/api/agent", as: [Agent].self) } catch { /* ignore */ }
    }

    func loadPending() async {
        guard let c = try? client() else { return }
        if let raw = try? await c.getRawJSON("/api/permission") {
            let items = Self.array(from: raw).compactMap { try? JSONDecoder().decode(PermissionItemDTO.self, from: JSONSerialization.data(withJSONObject: $0)) }
            pendingPermissions = items.map {
                PendingPermission(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    action: $0.action,
                    resources: $0.resources ?? [],
                    title: Self.permissionTitle($0),
                    createdAt: nil
                )
            }
        }
        if let raw = try? await c.getRawJSON("/api/question") {
            let items = Self.array(from: raw).compactMap { try? JSONDecoder().decode(QuestionItemDTO.self, from: JSONSerialization.data(withJSONObject: $0)) }
            pendingQuestions = items.map { PendingQuestion(id: $0.id, sessionID: $0.sessionID, questions: $0.questions ?? []) }
        }
    }

    func loadMessages(sessionID: String) async -> [Message] {
        guard let c = try? client() else { return [] }
        do { return try await c.getData("/api/session/\(sessionID)/message", as: [Message].self) }
        catch { return [] }
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

    private func handle(_ event: OpenCodeEvent) {
        let type = event.type
        if type.hasSuffix("text.delta") || type.hasSuffix("reasoning.delta") || type == "message.part.delta" {
            if let sid = event.sessionID, let d = event.delta ?? event.text {
                if type.hasSuffix("reasoning.delta") {
                    // keep reasoning separate; currently merged with a marker
                    liveText[sid, default: ""] += d
                } else {
                    liveText[sid, default: ""] += d
                }
            }
            return
        }
        if type.contains("permission") || type.contains("question") {
            Task { await loadPending() }
            return
        }
        if type.hasPrefix("session.") {
            switch type {
            case "session.idle":
                if let sid = event.sessionID { activeIDs.remove(sid) }
                Task { await loadSessions() }
            case "session.created", "session.updated", "session.deleted":
                Task { await loadSessions() }
            case "session.error":
                Task { await refreshAll() }
            default:
                break
            }
        }
    }

    // MARK: - Actions

    func sendPrompt(sessionID: String, text: String) async {
        guard let c = try? client(), !text.isEmpty else { return }
        do { try await c.postJSON("/api/session/\(sessionID)/prompt", json: ["prompt": ["text": text]]) }
        catch { lastError = error.localizedDescription }
    }

    func interrupt(sessionID: String) async {
        guard let c = try? client() else { return }
        do { try await c.postJSON("/api/session/\(sessionID)/interrupt") }
        catch { lastError = error.localizedDescription }
        activeIDs.remove(sessionID)
    }

    func replyPermission(_ p: PendingPermission, reply: String) async {
        guard let c = try? client(), let sid = p.sessionID else { return }
        do {
            try await c.postJSON("/api/session/\(sid)/permission/\(p.id)/reply", json: ["reply": reply])
            await loadPending()
        } catch { lastError = error.localizedDescription }
    }

    func replyQuestion(_ q: PendingQuestion, answers: [[String]]) async {
        guard let c = try? client(), let sid = q.sessionID else { return }
        do {
            try await c.postJSON("/api/session/\(sid)/question/\(q.id)/reply", json: ["answers": answers])
            await loadPending()
        } catch { lastError = error.localizedDescription }
    }

    func rejectQuestion(_ q: PendingQuestion) async {
        guard let c = try? client(), let sid = q.sessionID else { return }
        do {
            try await c.postJSON("/api/session/\(sid)/question/\(q.id)/reject")
            await loadPending()
        } catch { lastError = error.localizedDescription }
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
