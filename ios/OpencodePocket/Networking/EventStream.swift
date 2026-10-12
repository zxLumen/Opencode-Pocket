import Foundation

/// Streams opencode SSE events from `GET /api/event`.
enum EventStream {
    static func connect(base: URL, authorization: String) -> AsyncStream<OpenCodeEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2000)) { continuation in
            let task = Task {
                var attempts = 0
                while !Task.isCancelled {
                    do {
                        try await run(base: base, authorization: authorization, continuation: continuation)
                        attempts = 0
                    } catch {
                        // reconnect below
                    }
                    if Task.isCancelled { break }
                    attempts += 1
                    // 退避上限 30s，并加抖动，弱网时避免持续冲击。
                    let backoff = min(pow(2.0, Double(max(attempts - 1, 0))), 30)
                    let jitter = Double.random(in: 0...0.5)
                    try? await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        base: URL,
        authorization: String,
        continuation: AsyncStream<OpenCodeEvent>.Continuation
    ) async throws {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var p = comps.path
        if p.hasSuffix("/") { p = String(p.dropLast()) }
        comps.path = p + "/api/event"
        var req = URLRequest(url: comps.url ?? base)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.status((response as? HTTPURLResponse)?.statusCode ?? -1, "event stream")
        }

        var buffer = ""
        for try await line in bytes.lines {
            if line.isEmpty {
                if !buffer.isEmpty,
                   let data = buffer.data(using: .utf8),
                   let event = try? JSONDecoder().decode(OpenCodeEvent.self, from: data) {
                    continuation.yield(event)
                }
                buffer = ""
            } else if line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                buffer += payload
            }
            // other lines (": heartbeat", "event:", "id:") are ignored
        }
    }
}
