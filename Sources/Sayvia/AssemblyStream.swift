import Foundation
import AVFoundation

struct AssemblyTurns {
    private var turns: [Int: String] = [:]
    mutating func receive(_ event: [String: Any]) {
        guard event["type"] as? String == "Turn", event["end_of_turn"] as? Bool == true,
              let order = event["turn_order"] as? Int, order >= 0,
              let text = event["transcript"] as? String else { return }
        turns[order] = text
    }
    var text: String { turns.keys.sorted().compactMap { turns[$0] }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
}

// One ordered sender and one receiver own each connection. No automatic paid retry.
@MainActor
final class AssemblyStream {
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private var sender: Task<Void, Error>?
    private var receiver: Task<String, Error>?
    private var watchdog: Task<Void, Never>?
    private var begun = false
    private var terminating = false
    private var failure: Error?
    private var turns = AssemblyTurns()
    var onFinal: ((String) -> Void)?
    var partialText: String { turns.text }
    private var closed = false
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var timing: [String: Int] = [:]
    private var sentBytes = 0
    private var completion: CheckedContinuation<String, Error>?
    private var completedResult: Result<String, Error>?
    private func complete(_ result: Result<String, Error>) {
        guard completedResult == nil else { return }
        completedResult = result
        completion?.resume(with: result); completion = nil
    }
    var diagnostic: String {
        timing.keys.sorted().map { "\($0)=\(timing[$0]!)ms" }.joined(separator: " ") + " pcm_bytes=\(sentBytes)"
    }
    private func mark(_ name: String) { timing[name] = Int((ProcessInfo.processInfo.systemUptime - createdAt) * 1000) }

    nonisolated static func matches(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        return ["streaming.assemblyai.com", "streaming.us.assemblyai.com", "streaming.eu.assemblyai.com"].contains(url.host ?? "") && url.path == "/v3/ws"
    }
    nonisolated static func request(configuration: Configuration, key: String, sampleRate: Double, temporaryToken: Bool) throws -> URLRequest {
        let endpoint = try ModelService.endpoint(configuration.sttURL)
        guard Self.matches(configuration.sttURL), !key.isEmpty, (8000...96000).contains(sampleRate) else { throw AppError("AssemblyAI 配置或采样率无效。") }
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.scheme = "wss"
        url.queryItems = [URLQueryItem(name: "sample_rate", value: String(Int(sampleRate))), URLQueryItem(name: "speech_model", value: configuration.sttModel), URLQueryItem(name: "inactivity_timeout", value: "15")]
        if temporaryToken { url.queryItems!.append(URLQueryItem(name: "token", value: key)) }
        if !configuration.language.isEmpty {
            url.queryItems!.append(URLQueryItem(name: "language_codes", value: String(decoding: try JSONEncoder().encode([configuration.language]), as: UTF8.self)))
        }
        var request = URLRequest(url: url.url!)
        if !temporaryToken { request.setValue(key, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 20
        return request
    }
    init(configuration: Configuration, key: String, sampleRate: Double, terms: [String], paceReplay: Bool = false, temporaryToken: Bool = false, source: @escaping () throws -> Data?) throws {
        let request = try Self.request(configuration: configuration, key: key, sampleRate: sampleRate, temporaryToken: temporaryToken)
        // Dictionary values travel in a message, not a URL that proxies may log.
        let keyterms = Array(terms.filter { !$0.isEmpty && $0.count <= 100 && $0.split(separator: " ").count <= 6 }.prefix(100))
        session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        socket = session.webSocketTask(with: request); socket.maximumMessageSize = 1_000_000; socket.resume()
        receiver = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                while true {
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppError("识别服务响应无效。") }
                    switch event["type"] as? String {
                    case "Begin": begun = true; mark("begin")
                    case "Turn":
                        turns.receive(event)
                        if event["end_of_turn"] as? Bool == true { mark("last_final"); onFinal?(turns.text) }
                    case "Termination":
                        mark("termination")
                        guard terminating else { throw AppError("识别连接提前结束，音频已保留。") }
                        guard !turns.text.isEmpty else { throw AppError(AppError.noSpeech) }
                        complete(.success(turns.text))
                        return turns.text
                    case "Error", "error": throw AppError("AssemblyAI 拒绝识别请求，请检查模型、额度和网络。")
                    default: break
                    }
                }
            } catch { if case .success? = completedResult { throw error }; if failure == nil { failure = error }; cancel(); throw error }
        }
        sender = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let deadline = Date().addingTimeInterval(15)
                while !begun {
                    if let failure { throw failure }
                    guard Date() < deadline else { throw AppError("识别连接超时，音频已保留。") }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
                if !keyterms.isEmpty { try await sendJSON(["type": "UpdateConfiguration", "keyterms_prompt": keyterms]) }
                while let chunk = try source() {
                    try Task.checkCancellation()
                    if let failure { throw failure }
                    if chunk.isEmpty { try await Task.sleep(nanoseconds: 20_000_000); continue }
                    mark("audio_send_start")
                    try await socket.send(.data(chunk))
                    sentBytes += chunk.count; mark("audio_send_end")
                    // Microphone delivery already paces live audio. Sleeping again accumulates transport lag.
                    if paceReplay { try await Task.sleep(nanoseconds: UInt64(Double(chunk.count) / (sampleRate * 2) * 1_000_000_000)) }
                }
                mark("audio_eof")
                terminating = true
                mark("force_start")
                try await sendJSON(["type": "ForceEndpoint"])
                mark("force_end"); mark("terminate_start")
                try await sendJSON(["type": "Terminate"])
                mark("terminate_end")
            } catch { if case .success? = completedResult { throw error }; if failure == nil { failure = error }; cancel(); throw error }
        }
    }
    private func sendJSON(_ payload: [String: Any]) async throws {
        try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
    }
    func result(maxWait: TimeInterval = 8) async throws -> String {
        mark("result_start")
        // Bound every remaining send as well as the server's final response.
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxWait * 1_000_000_000))
            guard !Task.isCancelled, let self, completedResult == nil else { return }
            mark("deadline")
            failure = AppError("识别收尾等待超时，音频和已完成转写已保留，可在历史重试。")
            complete(.failure(failure!))
            sender?.cancel(); receiver?.cancel()
            socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        }
        defer { close() }
        return try await withTaskCancellationHandler {
            do {
                let result = try await withCheckedThrowingContinuation { continuation in
                    if let completedResult { continuation.resume(with: completedResult) }
                    else { completion = continuation }
                }
                try Task.checkCancellation()
                mark("result_end")
                return result
            } catch { throw failure ?? error }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancel() } }
    }
    func cancel() {
        complete(.failure(failure ?? CancellationError()))
        guard !closed else { return }; closed = true
        sender?.cancel(); receiver?.cancel(); watchdog?.cancel()
        // Send termination before closing, but never leave an orphaned connection waiting on network I/O.
        let socket = socket, session = session
        socket.send(.string("{\"type\":\"Terminate\"}")) { _ in socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    }
    private func close() { guard !closed else { return }; closed = true; watchdog?.cancel(); sender?.cancel(); receiver?.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
    static func transcribe(audio: URL, configuration: Configuration, key: String, terms: [String], temporaryToken: Bool = false, onFinal: (@MainActor (String) -> Void)? = nil, onDiagnostic: (@MainActor (String) -> Void)? = nil) async throws -> String {
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 5)
        let stream = try AssemblyStream(configuration: configuration, key: key, sampleRate: file.processingFormat.sampleRate, terms: terms, paceReplay: true, temporaryToken: temporaryToken) {
            guard file.framePosition < file.length else { return nil }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw AppError("无法分配音频缓冲区。") }
            try file.read(into: buffer)
            var data = try AudioSink.monoPCM(buffer)
            let minimum = Int(file.processingFormat.sampleRate / 20) * 2
            if data.count < minimum { data.append(Data(count: minimum - data.count)) }
            return data
        }
        stream.onFinal = onFinal
        defer { onDiagnostic?(stream.diagnostic) }
        return try await stream.result(maxWait: Double(file.length) / file.processingFormat.sampleRate + 15)
    }
}
