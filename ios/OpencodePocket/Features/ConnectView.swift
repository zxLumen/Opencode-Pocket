import SwiftUI
import UIKit

struct ConnectView: View {
    @Environment(PocketStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("https://pocket.example.com", text: $store.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("用户名", text: $store.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(Credentials.password.isEmpty ? "密码" : "密码（已保存，可留空）", text: $store.password)
                }

                Section {
                    Button {
                        Task { await store.connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if store.phase == .connecting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(store.phase == .connecting ? "连接中…" : "连接")
                            Spacer()
                        }
                    }
                    .disabled(store.phase == .connecting || store.baseURL.isEmpty)
                }

                if case let .failed(message) = store.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Opencode-Pocket")
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }
}
