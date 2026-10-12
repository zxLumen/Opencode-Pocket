import SwiftUI

struct ProvidersView: View {
    @Environment(PocketStore.self) private var store
    @State private var search = ""
    @State private var keyTarget: Integration?
    @State private var keyText = ""
    @State private var labelText = ""
    @State private var connecting = false

    private var filtered: [Integration] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list: [Integration] = store.integrations
        if !q.isEmpty {
            list = list.filter { integ in
                let name = integ.name.lowercased()
                let id = integ.id.lowercased()
                return name.contains(q) || id.contains(q)
            }
        }
        list.sort { a, b in
            if a.isConnected != b.isConnected { return a.isConnected }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return list
    }

    var body: some View {
        List {
            ForEach(filtered) { integ in
                Button { startConnect(integ) } label: { providerRow(integ) }
                    .buttonStyle(.plain)
            }
        }
        .searchable(text: $search, prompt: "搜索 provider（如 anthropic / openai / deepseek）")
        .navigationTitle("提供商")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.loadIntegrations() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .sheet(item: $keyTarget) { integ in
            keyEntrySheet(integ)
        }
    }

    @ViewBuilder
    private func providerRow(_ integ: Integration) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(integ.name)
                Text(integ.id).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            trailingBadge(integ)
        }
    }

    @ViewBuilder
    private func trailingBadge(_ integ: Integration) -> some View {
        if integ.isConnected {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if integ.supportsKey {
            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
        } else {
            Text("仅 OAuth/其它").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func startConnect(_ integ: Integration) {
        guard integ.supportsKey else { return }   // 目前仅支持 API Key
        keyText = ""; labelText = ""
        keyTarget = integ
    }

    private func keyEntrySheet(_ integ: Integration) -> some View {
        NavigationStack {
            Form {
                Section("连接 \(integ.name)") {
                    SecureField("API Key", text: $keyText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("备注（可选）", text: $labelText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("ID: \(integ.id)").font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        connect(integ)
                    } label: {
                        HStack { Spacer(); if connecting { ProgressView().padding(.trailing,6) }; Text("连接"); Spacer() }
                    }
                    .disabled(connecting || keyText.isEmpty)
                }
            }
            .navigationTitle("输入 API Key")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { keyTarget = nil } } }
        }
    }

    private func connect(_ integ: Integration) {
        connecting = true
        let k = keyText, l = labelText
        Task {
            let ok = await store.connectKey(integrationID: integ.id, key: k, label: l)
            connecting = false
            if ok { keyTarget = nil }
        }
    }
}
