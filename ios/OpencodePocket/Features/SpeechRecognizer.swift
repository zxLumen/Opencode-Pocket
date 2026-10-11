import Foundation
import Speech
import AVFoundation
import Observation

@MainActor
@Observable
final class SpeechRecognizer {
    var transcript = ""          // committed + current（供 UI 追加）
    var isRecording = false
    var errorText: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()

    private var committed = ""   // 已定稿文本
    private var current = ""     // 当前片段

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        errorText = nil
        committed = ""
        current = ""
        transcript = ""
        guard let recognizer, recognizer.isAvailable else { errorText = "语音识别不可用"; return }

        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
        guard speechOK else { errorText = "未授权语音识别"; return }

        let micOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { ok in c.resume(returning: ok) }
        }
        guard micOK else { errorText = "未授权麦克风"; return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            beginRequest()
        } catch {
            errorText = error.localizedDescription
            stop()
        }
    }

    /// 新建一次识别请求；定稿后自动重启，实现「连续听」。
    private func beginRequest() {
        guard isRecording, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation   // 听写模式：对话式、中英混更好
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if let text { self.current = text }
                self.transcript = self.committed + self.current
                if failed {
                    self.stop()
                } else if isFinal {
                    self.committed += self.current
                    self.current = ""
                    self.beginRequest()   // 继续听
                }
            }
        }
    }

    func stop() {
        isRecording = false
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        transcript = committed + current
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
