import SwiftUI

struct RootView: View {
    @Environment(PocketStore.self) private var store

    var body: some View {
        switch store.phase {
        case .connected:
            SessionListView()
        default:
            ConnectView()
        }
    }
}
