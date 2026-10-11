import Foundation

enum APIError: Error, LocalizedError {
    case badURL
    case status(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的服务器地址"
        case .status(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decode(let message): return "解析失败: \(message)"
        }
    }
}

struct APIClient: Sendable {
    let base: URL
    let authorization: String

    init(baseURL: String, username: String, password: String) throws {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { throw APIError.badURL }
        self.base = url
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        self.authorization = "Basic \(token)"
    }

    private func url(for path: String, query: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var p = comps.path
        if p.hasSuffix("/") { p = String(p.dropLast()) }
        comps.path = p + path
        if !query.isEmpty { comps.queryItems = query }
        return comps.url ?? base
    }

    func request(_ path: String, method: String = "GET",
                 query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: url(for: path, query: query))
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.status(-1, "无响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let data = try await request(path, query: query)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decode(String(describing: error)) }
    }

    /// GET that unwraps a `{ "data": T }` envelope, falling back to bare T.
    func getData<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let data = try await request(path, query: query)
        if let wrapped = try? JSONDecoder().decode(Wrapped<T>.self, from: data) { return wrapped.data }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decode(String(describing: error)) }
    }

    func getRawJSON(_ path: String, query: [URLQueryItem] = []) async throws -> Any {
        let data = try await request(path, query: query)
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    func postJSON(_ path: String, json: [String: Any]? = nil) async throws -> Data {
        try await request(path, method: "POST", json: json)
    }

    /// 上传附件到 Mac（经 /pocketd/upload），返回 opencode 可读取的 file:// uri。
    func upload(_ data: Data, contentType: String, name: String) async throws -> (uri: String, name: String) {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var p = comps.path
        if p.hasSuffix("/") { p = String(p.dropLast()) }
        comps.path = p + "/pocketd/upload"
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        var req = URLRequest(url: comps.url ?? base)
        req.httpMethod = "POST"
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: d, encoding: .utf8) ?? "")
        }
        struct UploadResult: Decodable { var uri: String; var name: String? }
        let r = try JSONDecoder().decode(UploadResult.self, from: d)
        return (r.uri, r.name ?? name)
    }
}
