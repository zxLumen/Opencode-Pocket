import SwiftUI

struct SessionListView: View {
    @Environment(PocketStore.self) private var store
    @State private var path: [String] = []
    @State private var showSettings = false

    private var groups: [(String, [Session])] {
        Dictionary(grouping: store.sessions, by: { $0.projectName })
            .map { (key, value) in
                (key, value.sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) })
            }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !store.pendingPermissions.isEmpty || !store.pendingQuestions.isEmpty {
                    Section("待处理") {
                        ForEach(store.pendingPermissions) { p in
                            Button { open(p.sessionID) } label: {
                                Label(p.title, systemImage: "lock.shield")
                            }
                        }
                        ForEach(store.pendingQuestions) { q in
                            Button { open(q.sessionID) } label: {
                                Label(q.questions.first?.header ?? "提问", systemImage: "questionmark.bubble")
                            }
                        }
                    }
                }

                ForEach(groups, id: \.0) { name, sessions in
                    Section(name) {
                        ForEach(sessions) { session in
                            Button { path.append(session.id) } label: { SessionRow(session: session) }
                                .buttonStyle(.plain)
                        }
                    }
                }

                if store.sessions.isEmpty {
                    Text("暂无会话").foregroundStyle(.secondary)
                }
            }
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
