import Foundation
import AVFoundation

// The one socket this client needs for realtime; a fake stands in for tests.
@MainActor protocol RealtimeSocket: AnyObject {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}
extension URLSessionWebSocketTask: RealtimeSocket {
    func close() { cancel(with: .normalClosure, reason: nil) }
}

// Bailian streaming ASR (duplex inference protocol) over one WebSocket that
// this client owns with the user's own key. One ordered PCM sender and one
// reader; supplier sentences are translated into the protocol core's events,
// so only stable finals are saved and only a complete final can be input.
@MainActor final class BailianStream {
    private let protocolCore = BailianRealtimeCandidate()
    private let converter: StreamingPCMResampler
    private let format: AVAudioFormat
    private let socket: RealtimeSocket
    private let taskID = UUID().uuidString.lowercased()
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var completion: CheckedContinuation<String, Error>?
    private var completed: Result<String, Error>?
    private var closed = false
    private var trace: LatencyRecorder?
    private let started = ProcessInfo.processInfo.systemUptime
    private var marks: [String: Int] = [:]
    private var finishAcceptedAt: Double?
    private var failurePhase: String?
    private var savedFinalText = ""
    // Supplier sentence finals by id (nil while open); open ones keep only their length.
    private var sentences: [String?] = []
    private var openChars: [Int: Int] = [:]
    var onFinal: ((String) -> Void)?
    /// Fires once when the session dies on its own, so a live recording can stop
    /// queueing PCM nobody will send.
    var onFailure: (() -> Void)?
    /// Fires once when `fallbackAfter` passes after the finish was sent
    /// without a complete final; the session keeps running.
    var onFallbackDue: (() -> Void)?
    private var phase: String { marks["complete"] != nil ? "complete" : finishAcceptedAt != nil ? "waiting_final" : marks["audio_eof"] != nil ? "waiting_finish" : "recording" }
    var diagnostic: String { marks.keys.sorted().map { "\($0)=\(marks[$0]!)ms" }.joined(separator: " ") + " pcm_bytes=\(protocolCore.inputBytes) segments=\(protocolCore.sentSegments) sentences=\(sentences.count) phase=\(failurePhase ?? phase)" }
    private func mark(_ name: String) { marks[name] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
    private func complete(_ result: Result<String, Error>) {
        guard completed == nil else { return }; completed = result
        completion?.resume(with: result); completion = nil
    }
    init(service: ModelService, sampleRate: Double, source: @escaping () throws -> Data?, socket: RealtimeSocket? = nil) throws {
        try BailianRealtimeCandidate.requireChannel(service)
        guard let address = service.configuration.realtimeURL, let url = URL(string: address) else { throw AppError(BailianRealtimeCandidate.blockedReason) }
        guard (8000...96000).contains(sampleRate), let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { throw AppError("实时音频采样率无效，音频已保留。") }
        self.format = format; converter = try StreamingPCMResampler(format: format)
        if let socket { self.socket = socket } else {
            var request = URLRequest(url: url, timeoutInterval: 3600)
            request.setValue("Bearer \(service.sttKey)", forHTTPHeaderField: "Authorization")
            let task = service.session.webSocketTask(with: request)
            task.maximumMessageSize = 1_000_000; task.resume(); self.socket = task
        }
        let start = try Self.runTask(id: taskID, model: service.configuration.sttModel + "-streaming", terms: service.realtimeTerms,
                                     context: service.realtimeContext, language: service.configuration.language)
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while !closed {
                    let data: Data
                    switch try await self.socket.receive() {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: throw AppError("实时识别响应格式无效，音频已保留。")
                    }
                    try Task.checkCancellation()
                    try receive(data)
                    if completed != nil { return }
                }
            } catch { fail(error is AppError ? error : AppError("实时识别连接已结束，音频已保留；不会自动重传。")) }
        }
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                try await send(.string(start)); mark("run_task_sent")
                var eof = false
                while !closed {
                    try Task.checkCancellation()
                    if !eof {
                        if let pcm = try source() {
                            if !pcm.isEmpty {
                                guard pcm.count % 2 == 0, pcm.count <= Int(sampleRate * 0.2) * 2 else { throw AppError("实时音频片段无效，音频已保留。") }
                                let frames = pcm.count / 2
                                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!; buffer.frameLength = AVAudioFrameCount(frames)
                                pcm.withUnsafeBytes { bytes in
                                    for index in 0..<frames { buffer.floatChannelData![0][index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768 }
                                }
                                let converted = try converter.appendPCM(buffer)
                                if !converted.isEmpty { try protocolCore.appendPCM(converted) }
                            }
                        } else {
                            let tail = try converter.finish(); if !tail.isEmpty { try protocolCore.appendPCM(tail) }
                            protocolCore.finish(); eof = true; mark("audio_eof")
                        }
                    }
                    while let message = try protocolCore.nextMessage() {
                        // Consumed before sending: a failed send never requeues
                        // audio, replays or opens another paid session.
                        guard let event = try JSONSerialization.jsonObject(with: message) as? [String: Any], let type = event["type"] as? String else { throw AppError("实时音频片段无效，音频已保留。") }
                        switch type {
                        case "input_audio_buffer.append":
                            guard let audio = (event["audio"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw AppError("实时音频片段无效，音频已保留。") }
                            try await send(.data(audio)); mark("last_send")
                        case "session.finish":
                            try await send(.string(Self.finishTask(id: taskID)))
                            finishAcceptedAt = ProcessInfo.processInfo.systemUptime; mark("finish_sent"); return
                        default: break // Streaming ASR recognizes as audio arrives; commit is a local seal.
                        }
                        try Task.checkCancellation()
                    }
                    if protocolCore.status == "connecting", ProcessInfo.processInfo.systemUptime - started > 15 { throw AppError("实时识别启动超时，音频已保留。") }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            } catch { fail(error is AppError || error is CancellationError ? error : AppError("实时音频发送失败，音频已保留；不会自动重传。")) }
        }
    }
    static func runTask(id: String, model: String, terms: [String], context: String, language: String) throws -> String {
        let vocabulary = terms.filter { !$0.isEmpty && $0.count <= 100 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(100)
        var parameters: [String: Any] = ["format": "pcm", "sample_rate": 16000, "vad_model": "near_meeting_16k",
                                         "vocabulary": Dictionary(vocabulary.map { ($0, 3) }, uniquingKeysWith: { first, _ in first })]
        if ["zh", "en"].contains(language) { parameters["language_hints"] = [language] }
        let reference = String(context.prefix(400))
        let input: [String: Any] = reference.isEmpty ? [:] : ["context": [["role": "user", "content": [["type": "input_text", "text": reference]]]]]
        let value: [String: Any] = ["header": ["action": "run-task", "task_id": id, "streaming": "duplex"],
                                    "payload": ["task_group": "audio", "task": "asr", "function": "recognition", "model": model, "parameters": parameters, "input": input]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    static func finishTask(id: String) -> String {
        "{\"header\":{\"action\":\"finish-task\",\"task_id\":\"\(id)\",\"streaming\":\"duplex\"},\"payload\":{\"input\":{}}}"
    }
    // A stalled send fails the session so the file leg takes over.
    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let socket = socket
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await socket.send(message) }
            group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw AppError("实时音频发送超时，音频已保留；不会自动重传。") }
            try await group.next(); group.cancelAll()
        }
    }
    private func feed(_ event: [String: Any]) throws { try protocolCore.receive(JSONSerialization.data(withJSONObject: event)) }
    private func receive(_ data: Data) throws {
        guard data.count <= 1_000_000, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = value["header"] as? [String: Any], header["task_id"] as? String == taskID,
              let event = header["event"] as? String else { throw AppError("实时识别响应格式无效，音频已保留。") }
        switch event {
        case "task-started":
            mark("supplier_started"); try feed(["type": "session.updated"])
        case "result-generated":
            guard let sentence = ((value["payload"] as? [String: Any])?["output"] as? [String: Any])?["sentence"] as? [String: Any] else { throw AppError("实时识别响应格式无效，音频已保留。") }
            if sentence["heartbeat"] as? Bool == true { return }
            guard let id = sentence["sentence_id"] as? Int, (1...1000).contains(id), let end = sentence["sentence_end"] as? Bool else { throw AppError("实时识别片段身份无效。") }
            if id > sentences.count {
                guard id == sentences.count + 1 else { throw AppError("实时识别片段序号不连续，音频已保留。") }
                sentences.append(nil); try feed(["type": "conversation.item.created", "item_id": "sentence_\(id)"])
            }
            let text = sentence["text"] as? String ?? ""
            // Unstable text never reaches history; its length only decides a stalled tail.
            guard end else { if sentences[id - 1] == nil { openChars[id] = min(text.trimmingCharacters(in: .whitespacesAndNewlines).count, 20_000) }; return }
            if let previous = sentences[id - 1] { guard previous == text else { throw AppError("实时识别返回相互矛盾的终稿，音频已保留。") }; return }
            sentences[id - 1] = text; openChars[id] = nil; mark("sentence_final")
            try feed(["type": "conversation.item.input_audio_transcription.completed", "item_id": "sentence_\(id)", "transcript": text])
        case "task-finished":
            mark("supplier_finished"); try feed(["type": "session.finished"])
        case "task-failed":
            throw AppError("实时识别失败，音频已保留；不会自动重传。")
        default:
            throw AppError("实时识别响应格式无效，音频已保留。")
        }
        publishFinals()
    }
    private func publishFinals() {
        // Stable sentence finals are recoverable even if the session later fails.
        let text = protocolCore.finalizedText
        if !text.isEmpty && text != savedFinalText { savedFinalText = text; mark("sentence_final_received"); onFinal?(text) }
        guard let completedText = protocolCore.completedText else { return }
        mark("final_received"); socket.close(); mark("complete"); complete(.success(completedText))
    }
    // 2026-10-09: long sessions got every final but one opened sentence and never
    // task-finished. If no open sentence ever carried text, the finals are the
    // whole transcript; any open text still fails, nothing is guessed.
    private func dropSilentTail() -> Bool {
        let open = sentences.indices.filter { sentences[$0] == nil }.map { $0 + 1 }
        guard !open.isEmpty, open.allSatisfy({ (openChars[$0] ?? 0) == 0 }),
              sentences.contains(where: { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) else { return false }
        do {
            for id in open { sentences[id - 1] = ""; try feed(["type": "conversation.item.input_audio_transcription.completed", "item_id": "sentence_\(id)", "transcript": ""]) }
            try feed(["type": "session.finished"])
        } catch { return false }
        mark("tail_dropped"); publishFinals(); return completed != nil
    }
    private func fail(_ error: Error) {
        if case .success? = completed { return }
        // Only the first, genuine failure notifies; user cancellation clears it.
        let onFailure = completed == nil ? self.onFailure : nil
        failurePhase = failurePhase ?? phase
        protocolCore.fail(); complete(.failure(error)); cancel()
        onFailure?()
    }
    func result(maxWait: TimeInterval = 20, fallbackAfter: TimeInterval? = nil, trace: LatencyRecorder? = nil) async throws -> String {
        self.trace = trace; mark("result_start")
        let resultStarted = ProcessInfo.processInfo.systemUptime
        watchdog = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, completed == nil {
                // 8s to drain and send the finish; then the supplier's final may take
                // up to maxWait (task-finished took 0.4-9.8s on 2026-10-07).
                let deadline = finishAcceptedAt.map { $0 + maxWait } ?? (resultStarted + 8)
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if let fallbackAfter, let accepted = finishAcceptedAt, marks["fallback_due"] == nil,
                   ProcessInfo.processInfo.systemUptime >= accepted + fallbackAfter {
                    mark("fallback_due"); onFallbackDue?()
                }
                if remaining <= 0 {
                    if finishAcceptedAt != nil, dropSilentTail() { return }
                    mark("watchdog_expired"); fail(AppError("实时收尾等待超时，音频已保留；不会自动重传。")); return
                }
                do { try await Task.sleep(nanoseconds: UInt64(min(0.05, remaining) * 1_000_000_000)) } catch { return }
            }
        }
        defer { cancel() }
        let text = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let completed { continuation.resume(with: completed) } else { completion = continuation }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancel() } }
        try Task.checkCancellation(); return text
    }
    func cancel() {
        onFailure = nil; complete(.failure(CancellationError()))
        guard !closed else { return }; closed = true
        protocolCore.cancel(); sender?.cancel(); receiver?.cancel(); watchdog?.cancel()
        socket.close()
    }
}
