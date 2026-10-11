import SwiftUI

struct SessionListView: View {
    @Environment(PocketStore.self) private var store
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var search = ""
    @State private var collapsed: Set<String> = []        // 整个分区折叠
    @State private var expandedGroups: Set<String> = []    // 分区内展开全部（默认只显示前 5）

    private let previewLimit = 5

    private var filtered: [Session] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.sessions }
        return store.sessions.filter { s in
            s.displayTitle.lowercased().contains(q)
                || s.projectName.lowercased().contains(q)
                || (s.directory?.lowercased().contains(q) ?? false)
                || (s.agent?.lowercased().contains(q) ?? false)
        }
    }

    /// 组内按最近活跃(updated)倒序；组间也按"该组最近活跃"倒序。
    private var groups: [(String, [Session])] {
        Dictionary(grouping: filtered, by: { $0.projectName })
            .map { (name, list) -> (String, [Session], Double) in
                let sorted = list.sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }
                return (name, sorted, sorted.first?.time?.updated ?? 0)
            }
            .sorted { $0.2 > $1.2 }
            .map { ($0.0, $0.1) }
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !store.pendingPermissions.isEmpty || !store.pendingQuestions.isEmpty || !store.pendingForms.isEmpty {
                    Section("待处理") {
                        ForEach(store.pendingPermissions) { p in
                            Button { open(p.sessionID) } label: { Label(p.title, systemImage: "lock.shield") }
                        }
                        ForEach(store.pendingQuestions) { q in
                            Button { open(q.sessionID) } label: {
                                Label(q.questions.first?.header ?? "提问", systemImage: "questionmark.bubble")
                            }
                        }
                        ForEach(store.pendingForms) { f in
                            Button { open(f.sessionID) } label: {
                                Label(f.title, systemImage: "list.bullet.rectangle")
                            }
                        }
                    }
                }

                ForEach(groups, id: \.0) { name, sessions in
                    Section {
                        if !collapsed.contains(name) {
                            let showAll = expandedGroups.contains(name) || isSearching
                            let visible = showAll ? sessions : Array(sessions.prefix(previewLimit))

                            ForEach(visible) { session in
                                Button { path.append(session.id) } label: { SessionRow(session: session) }
                                    .buttonStyle(.plain)
                            }

                            if !isSearching && sessions.count > previewLimit {
                                if expandedGroups.contains(name) {
                                    Button("收起") { expandedGroups.remove(name) }
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("展开其余 \(sessions.count - previewLimit) 个") { expandedGroups.insert(name) }
                                        .font(.caption)
                                }
                            }
                        }
                    } header: {
                        Button { toggleCollapse(name) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: collapsed.contains(name) ? "chevron.right" : "chevron.down")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(sessions.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if store.sessions.isEmpty {
                    Text("暂无会话").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索会话（标题 / 工程 / 目录 / agent）")
            .navigationTitle("会话")
            .refreshable { await store.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: String.self) { id in
                SessionDetailView(sessionID: id)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: store.deepLinkSessionID) { _, newValue in
                if let id = newValue, store.session(id) != nil {
                    path.append(id)
                    store.deepLinkSessionID = nil
                }
            }
        }
    }

    private func toggleCollapse(_ name: String) {
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
    }

    private func open(_ sessionID: String?) {
        guard let sessionID else { return }
        path.append(sessionID)
    }
}

struct SessionRow: View {
    @Environment(PocketStore.self) private var store
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(store.activeIDs.contains(session.id) ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 9, height: 9)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label(session.projectName, systemImage: "folder")
                    if let agent = session.agent { Text(agent) }
                    if let model = session.model?.id { Text(model) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            let pending = store.pendingCount(for: session.id)
            if pending > 0 {
                Text("\(pending)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
