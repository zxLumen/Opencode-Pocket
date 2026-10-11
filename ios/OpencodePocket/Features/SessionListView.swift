import SwiftUI

struct SessionListView: View {
    @Environment(PocketStore.self) private var store
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var expandedGroups: Set<String> = []

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

    private var favoriteSessions: [Session] {
        filtered.filter { store.favorites.contains($0.id) }
            .sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }
    }

    /// 组内按最近活跃倒序；组间按"该组最近活跃"倒序。
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
                            Button { open(f.sessionID) } label: { Label(f.title, systemImage: "list.bullet.rectangle") }
                        }
                    }
                }

                if !favoriteSessions.isEmpty {
                    Section("收藏") {
                        ForEach(favoriteSessions) { session in
                            SessionRow(session: session) { path.append(session.id) }
                        }
                    }
                }

                ForEach(groups, id: \.0) { name, sessions in
                    Section {
                        if !collapsed.contains(name) {
                            let showAll = expandedGroups.contains(name) || isSearching
                            let visible = showAll ? sessions : Array(sessions.prefix(previewLimit))

                            ForEach(visible) { session in
                                SessionRow(session: session) { path.append(session.id) }
                            }

                            if !isSearching && sessions.count > previewLimit {
                                if expandedGroups.contains(name) {
                                    Button("收起") { expandedGroups.remove(name) }.font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("展开其余 \(sessions.count - previewLimit) 个") { expandedGroups.insert(name) }.font(.caption)
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

struct BlinkingDot: View {
    let color: Color
    let blink: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(blink ? (on ? 1 : 0.2) : 1)
            .onAppear {
                guard blink else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct SessionRow: View {
    @Environment(PocketStore.self) private var store
    let session: Session
    let onOpen: () -> Void

    private var state: DotState { store.dotState(for: session) }

    private var color: Color {
        switch state {
        case .pending: return .orange
        case .running: return .yellow
        case .done: return .green
        case .idle: return Color.secondary.opacity(0.4)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    BlinkingDot(color: color, blink: state == .pending)
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

                    Spacer(minLength: 4)

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
            }
            .buttonStyle(.plain)

            Button { store.toggleFavorite(session.id) } label: {
                Image(systemName: store.isFavorite(session.id) ? "star.fill" : "star")
                    .foregroundStyle(store.isFavorite(session.id) ? Color.yellow : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
