import SwiftUI

struct ModelsView: View {
    @Environment(PocketStore.self) private var store
    /// 传 sessionID 则点击=切换该会话模型；否则点击=设为默认模型。
    let sessionID: String?

    @State private var search = ""

    private var groups: [(String, [ModelRef])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = store.modelOptions.filter { q.isEmpty || $0.label.lowercased().contains(q) }
        return Dictionary(grouping: list, by: { $0.providerID })
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.0) { provider, models in
                Section(provider) {
                    ForEach(models, id: \.label) { m in
                        HStack {
                            Button { select(m) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.id)
                                    Text(m.label).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if store.defaultModelLabel == m.label {
                                Text("默认").font(.caption2).foregroundStyle(.blue)
                            }
                            Button { store.toggleFavoriteModel(m) } label: {
                                Image(systemName: store.isFavoriteModel(m) ? "star.fill" : "star")
                                    .foregroundStyle(store.isFavoriteModel(m) ? Color.yellow : Color.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if store.modelOptions.isEmpty {
                Text("暂无模型（先在「提供商」里连接一个 provider）").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $search, prompt: "搜索模型")
        .navigationTitle(sessionID == nil ? "模型（默认）" : "切换模型")
    }

    private func select(_ m: ModelRef) {
        Task {
            if let sid = sessionID {
                await store.switchModel(sessionID: sid, model: m)
            } else {
                await store.setDefaultModel(m)
            }
        }
    }
}
