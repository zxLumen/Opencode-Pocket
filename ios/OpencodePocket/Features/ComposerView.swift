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
    @State private var lastTranscript = ""
    @State private var uploading = false
    @State private var uploadError: String?

    /// 任何情况都能发送（上传中除外）：空消息会在 send() 里变成「继续」。
    private var canSend: Bool {
        !uploading
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

            if let e = uploadError, !e.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("图片上传失败：\(e)")
                    Spacer()
                    Button { uploadError = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .font(.caption).foregroundStyle(.orange)
                .padding(.horizontal, 14)
            } else if let e = speech.errorText, !e.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(e)
                    Spacer()
                }
                .font(.caption).foregroundStyle(.orange)
                .padding(.horizontal, 14)
            } else if speech.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("聆听中… 说出你的指令")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            }

            Picker("mode", selection: modeBinding) {
                Text("Plan").tag("plan")
                Text("Build").tag("build")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(uploading ? Color.secondary : Color.accentColor)
                }
                .disabled(uploading)

                TextField("输入指令…（留空点发送＝继续）", text: $text, axis: .vertical)
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
        .onAppear { if text.isEmpty, let d = store.drafts[sessionID] { text = d } }
        .onChange(of: text) { _, v in store.drafts[sessionID] = v }
        .onChange(of: speech.transcript) { _, t in
            guard speech.isRecording else { return }
            // 只追加增量：保留手动输入的换行/编辑，新说的话往后加
            if t.hasPrefix(lastTranscript) {
                text += String(t.dropFirst(lastTranscript.count))
            }
            lastTranscript = t
        }
        .onDisappear { speech.stop() }
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { store.session(sessionID)?.agent ?? "" },
            set: { v in Task { await store.switchAgent(sessionID: sessionID, agent: v) } }
        )
    }

    private func toggleSpeech() {
        if speech.isRecording {
            speech.stop()
        } else {
            lastTranscript = ""
            speech.toggle()
        }
    }

    private func handlePhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        uploading = true
        uploadError = nil
        defer { uploading = false; photoItems = [] }
        var index = 0
        for item in items {
            index += 1
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.8) else {
                uploadError = "有图片读取失败（格式不支持？）"
                continue
            }
            let name = "photo-\(Int(Date().timeIntervalSince1970))-\(index).jpg"
            if let att = await store.uploadImage(jpeg, contentType: "image/jpeg", name: name) {
                attachments.append(att)
            } else {
                uploadError = store.lastError ?? "服务器返回失败"
            }
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        // 空消息（只有空白、且没有附件）→ 发「继续」，让 agent 接着做。
        let value = (trimmed.isEmpty && attachments.isEmpty) ? "继续" : trimmed
        let files = attachments
        text = ""
        attachments = []
        speech.stop()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { await store.sendPrompt(sessionID: sessionID, text: value, attachments: files) }
    }
}
