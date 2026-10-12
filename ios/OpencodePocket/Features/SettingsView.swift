import SwiftUI

struct SettingsView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("地址", text: $store.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $store.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $store.password)
                }

                Section {
                    Button("重新连接") {
                        Task { await store.connect(); dismiss() }
                    }
                    Button("断开", role: .destructive) {
                        store.disconnect(); dismiss()
                    }
                }

                Section("模型与提供商") {
                    NavigationLink { ModelsView(sessionID: nil) } label: { Label("模型（默认）", systemImage: "cpu") }
                    NavigationLink { ProvidersView() } label: { Label("提供商（添加 API Key）", systemImage: "key") }
                }

                Section("状态") {
                    LabeledContent("版本", value: store.serverVersion ?? "—")
                    LabeledContent("会话数", value: "\(store.sessions.count)")
                    LabeledContent("运行中", value: "\(store.activeIDs.count)")
                }

                Section("可用 Agent") {
                    ForEach(store.agents) { agent in
                        VStack(alignment: .leading) {
                            Text(agent.displayName)
                            if let d = agent.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }

                if let error = store.lastError {
                    Section("最近错误") {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("设置")
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
