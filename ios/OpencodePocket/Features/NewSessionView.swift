import SwiftUI

struct NewSessionView: View {
    @Environment(PocketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var directory = ""
    @State private var agent = ""
    @State private var modelLabel = ""
    @State private var busy = false

    private var models: [ModelRef] { store.modelOptions }
    private var selectedModel: ModelRef? { models.first { $0.label == modelLabel } }

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

                Section("模型") {
                    Picker("模型", selection: $modelLabel) {
                        Text("默认").tag("")
                        ForEach(models, id: \.label) { m in Text(m.label).tag(m.label) }
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
                if modelLabel.isEmpty {
                    let preferred = store.defaultModelLabel
                    if !preferred.isEmpty, models.contains(where: { $0.label == preferred }) {
                        modelLabel = preferred
                    } else if let s = store.suggestedModel?.label {
                        modelLabel = s
                    } else {
                        modelLabel = models.first?.label ?? ""
                    }
                }
            }
        }
    }

    private func create() {
        busy = true
        Task {
            let id = await store.createSession(directory: directory,
                                               agent: agent.isEmpty ? nil : agent,
                                               model: selectedModel)
            busy = false
            if let id {
                onCreated(id)
                dismiss()
            }
        }
    }
}
