import Foundation

// MARK: - Session

struct ModelRef: Codable, Hashable, Sendable {
    var id: String
    var providerID: String
    var variant: String?

    var label: String { "\(providerID)/\(id)" }
}

struct Session: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String?
    var slug: String?
    var projectID: String?
    var agent: String?
    var model: ModelRef?
    var cost: Double?
    var tokens: Tokens?
    var outcome: String?
    var time: TimeInfo?
    var location: Location?

    struct Location: Codable, Hashable, Sendable { var directory: String? }
    struct TimeInfo: Codable, Hashable, Sendable {
        var created: Double?
        var updated: Double?
        var idle: Double?
    }
    struct Tokens: Codable, Hashable, Sendable {
        var input: Int?
        var output: Int?
        var reasoning: Int?
        var cache: Cache?
        struct Cache: Codable, Hashable, Sendable { var read: Int?; var write: Int? }
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let s = slug, !s.isEmpty { return s }
        return id
    }
    var directory: String? { location?.directory }
    var projectName: String {
        guard let d = directory, !d.isEmpty else { return "—" }
        return URL(fileURLWithPath: d).lastPathComponent
    }
}

// MARK: - Message

struct Message: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var type: String?
    var agent: String?
    var previous: String?
    var model: ModelRef?
    var time: TimeInfo?
    var content: [Part]?
    var text: String?          // 用户/合成消息使用顶层 text

    struct TimeInfo: Codable, Hashable, Sendable {
        var created: Double?
        var streamed: Double?
        var completed: Double?
    }

    var isUser: Bool { type == "user" }
    var isAssistant: Bool { type == "assistant" }

    var contentText: String {
        (content ?? []).compactMap { $0.text }.joined(separator: "\n")
    }
    /// 顶层 text 优先，否则用 content 里的 text 片段。
    var displayText: String {
        if let t = text, !t.isEmpty { return t }
        return contentText
    }
    var tools: [(name: String, status: String?)] {
        (content ?? []).compactMap { part in
            guard part.type == "tool", let name = part.name, !name.isEmpty else { return nil }
            return (name, part.state?.status)
        }
    }
}

struct Part: Codable, Hashable, Sendable {
    var type: String?
    var text: String?
    var name: String?
    var state: PartState?

    struct PartState: Codable, Hashable, Sendable { var status: String? }
}

// MARK: - Agent

struct Agent: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String?
    var description: String?
    var mode: String?

    var displayName: String { name ?? id }
}

// MARK: - Pending approval / question

struct PendingPermission: Identifiable, Hashable, Sendable {
    var id: String
    var sessionID: String?
    var action: String?
    var resources: [String]
    var title: String
    var createdAt: Double?
}

struct QuestionInfo: Codable, Hashable, Sendable {
    var question: String
    var header: String
    var options: [QuestionOption]
    var multiple: Bool?
    var custom: Bool?
}

struct QuestionOption: Codable, Hashable, Sendable {
    var label: String
    var description: String?
}

struct PendingQuestion: Identifiable, Hashable, Sendable {
    var id: String
    var sessionID: String?
    var questions: [QuestionInfo]
}

// MARK: - Event

struct OpenCodeEvent: Decodable, Sendable {
    var id: String?
    var type: String
    var directory: String?
    var sessionID: String?
    var delta: String?
    var text: String?
    var action: String?

    private enum Keys: String, CodingKey {
        case id, type, location, data
        case directory, sessionID, delta, text, action
    }
    private struct Loc: Decodable { var directory: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        let loc = try? c.decodeIfPresent(Loc.self, forKey: .location)
        if let inner = loc ?? nil { directory = inner.directory }
        if let data = try? c.nestedContainer(keyedBy: Keys.self, forKey: .data) {
            sessionID = try? data.decodeIfPresent(String.self, forKey: .sessionID)
            delta = try? data.decodeIfPresent(String.self, forKey: .delta)
            text = try? data.decodeIfPresent(String.self, forKey: .text)
            action = try? data.decodeIfPresent(String.self, forKey: .action)
        }
    }
}

// MARK: - Forms (也就是 question)

struct FormInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var sessionID: String
    var title: String
    var fields: [FormField]
}

struct FormField: Codable, Hashable, Sendable {
    var key: String
    var type: String                 // string | number | integer | boolean | multiselect | external
    var title: String?
    var description: String?
    var required: Bool?
    var hidden: Bool?
    var options: [FormOption]?
    var url: String?

    var displayTitle: String { title ?? key }
}

struct FormOption: Codable, Hashable, Sendable {
    var value: String
    var label: String
    var description: String?
}

// MARK: - Wrappers

struct Wrapped<T: Decodable>: Decodable {
    let data: T
}
