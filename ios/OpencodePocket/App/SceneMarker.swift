import Foundation
import SwiftUI

/// 供 Mac 续签脚本读取的前后台标记。
/// 写到 App 沙盒 Documents/ios-scene.json，Mac 用 `devicectl device copy from` 读取。
enum SceneMarker {
    private static let fileName = "ios-scene.json"

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static func write(_ phase: ScenePhase) {
        switch phase {
        case .active: write("foreground")
        case .inactive: write("inactive")
        case .background: write("background")
        default: write("unknown")
        }
    }

    static func write(_ state: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: String] = [
            "state": state,
            "at": formatter.string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 前台心跳：每 60 秒刷新时间戳，避免长时间停留导致标记过期。
    static func heartbeat() async {
        while !Task.isCancelled {
            write("foreground")
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}
