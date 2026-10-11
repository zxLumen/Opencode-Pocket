import SwiftUI

struct ComposerView: View {
    let sessionID: String
    @Environment(PocketStore.self) private var store
    @State private var text = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入指令…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            Button {
                send()
            } label: {
                Image(systemName: "paperplane.fill")
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .background(.bar)
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        Task { await store.sendPrompt(sessionID: sessionID, text: value) }
    }
}
