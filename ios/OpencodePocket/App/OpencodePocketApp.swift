import SwiftUI

@main
struct OpencodePocketApp: App {
    @State private var store = PocketStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    if Credentials.isConfigured { await store.connect() }
                }
                .onOpenURL { store.handleDeepLink($0) }
        }
    }
}
