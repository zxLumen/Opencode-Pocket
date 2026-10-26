import SwiftUI

@main
struct OpencodePocketApp: App {
    @State private var store = PocketStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    if Credentials.isConfigured { await store.connect() }
                }
                .onOpenURL { store.handleDeepLink($0) }
                .onChange(of: scenePhase) { _, phase in
                    SceneMarker.write(phase)
                    switch phase {
                    case .active:
                        Task { await store.handleBecameActive() }
                    case .background:
                        // 后台停掉 SSE / 轮询，避免空转与回前台重连风暴。
                        store.suspend()
                    default:
                        break
                    }
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await SceneMarker.heartbeat()
                }
        }
    }
}
