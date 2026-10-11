import SwiftUI

struct NewSessionView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var directory = ""
    @State private var agent = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("工作目录") {
                    TextField("/Users/you/Projects/xxx", text: $directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ForEach(store.knownDirectories, id: \.self) { d in
                        Button { directory = d } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(d).font(.caption).lineLimit(1)
                                Spacer()
                                if directory == d { Image(systemName: "checkmark").foregroundStyle(.blue) }
                            }
                        }
                    }
                }

                Section("Agent") {
                    Picker("Agent", selection: $agent) {
                        Text("默认").tag("")
                        ForEach(store.agents) { a in Text(a.displayName).tag(a.id) }
                    }
                }

                Section {
                    Button {
                        create()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text("创建会话")
                            Spacer()
                        }
                    }
                    .disabled(busy || directory.isEmpty)
                }
            }
            .navigationTitle("新建会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear {
                if directory.isEmpty { directory = store.knownDirectories.first ?? "" }
            }
        }
    }

    private func create() {
        busy = true
        Task {
            let id = await store.createSession(directory: directory, agent: agent.isEmpty ? nil : agent)
            busy = false
            if let id {
                onCreated(id)
                dismiss()
            }
        }
    }
}
