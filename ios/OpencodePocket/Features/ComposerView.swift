import SwiftUI
import UIKit
import PhotosUI

struct ComposerView: View {
    let sessionID: String
    @Environment(PocketStore.self) private var store
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var speech = SpeechRecognizer()
    @State private var speechBase = ""
    @State private var uploading = false

    private var canSend: Bool {
        !uploading && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            ZStack(alignment: .topTrailing) {
                                if let d = a.data, let ui = UIImage(data: d) {
                                    Image(uiImage: ui).resizable().scaledToFill()
                                        .frame(width: 54, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemFill))
                                        .frame(width: 54, height: 54)
                                }
                                Button { attachments.removeAll { $0.id == a.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption).foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(uploading ? Color.secondary : Color.accentColor)
                }
                .disabled(uploading)

                TextField("输入指令…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)

                Button { toggleSpeech() } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 20))
                        .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                }

                Button { send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? Color.accentColor : Color(.tertiarySystemFill)))
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
        .onChange(of: photoItems) { _, items in Task { await handlePhotos(items) } }
        .onChange(of: speech.transcript) { _, t in
            guard speech.isRecording else { return }
            // 追加到已有内容之后（不覆盖），并随识别结果实时增长
            text = speechBase.isEmpty ? t : speechBase + t
        }
        .onDisappear { speech.stop() }
    }

    private func toggleSpeech() {
        if speech.isRecording {
            speech.stop()
        } else {
            speechBase = text   // 记住当前输入框内容作为前缀
            speech.toggle()
        }
    }

    private func handlePhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        uploading = true
        defer { uploading = false; photoItems = [] }
        var index = 0
        for item in items {
            index += 1
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.8) else { continue }
            let name = "photo-\(Int(Date().timeIntervalSince1970))-\(index).jpg"
            if let att = await store.uploadImage(jpeg, contentType: "image/jpeg", name: name) {
                attachments.append(att)
            }
        }
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = attachments
        text = ""
        attachments = []
        speech.stop()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { await store.sendPrompt(sessionID: sessionID, text: value, attachments: files) }
    }
}
