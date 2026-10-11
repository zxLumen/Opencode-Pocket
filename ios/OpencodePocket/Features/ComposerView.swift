import SwiftUI
import UIKit
import PhotosUI

struct ComposerView: View {
    let sessionID: String
    @Environment(PocketStore.self) private var store
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var speech = SpeechRecognizer()
    @State private var uploading = false

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            ZStack(alignment: .topTrailing) {
                                if let d = a.data, let ui = UIImage(data: d) {
                                    Image(uiImage: ui).resizable().scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemFill))
                                        .frame(width: 56, height: 56)
                                }
                                Button { attachments.removeAll { $0.id == a.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            if speech.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("正在聆听…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 6) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.title3)
                }
                .disabled(uploading)

                TextField("输入指令…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)

                Button { speech.toggle() } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic").font(.title3)
                        .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                }

                Button { send() } label: {
                    Image(systemName: uploading ? "ellipsis.circle" : "paperplane.fill")
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploading || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
        .onChange(of: photoItem) { _, item in Task { await handlePhoto(item) } }
        .onChange(of: speech.transcript) { _, t in if speech.isRecording { text = t } }
        .onDisappear { speech.stop() }
    }

    private func handlePhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploading = true
        defer { uploading = false; photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.8) else { return }
        let name = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
        if let att = await store.uploadImage(jpeg, contentType: "image/jpeg", name: name) {
            attachments.append(att)
        }
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uploading, !value.isEmpty || !attachments.isEmpty else { return }
        let files = attachments
        text = ""
        attachments = []
        speech.stop()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { await store.sendPrompt(sessionID: sessionID, text: value, attachments: files) }
    }
}
