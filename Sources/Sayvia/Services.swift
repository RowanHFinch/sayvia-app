import Foundation
import Security
import CryptoKit
import AVFoundation
import LocalAuthentication

struct Keychain {
    // One key per provider host: recognition and cleanup on the same provider
    // (for example one Bailian region) share it; a different host never sees it.
    static func account(endpoint: String) -> String { "key-" + (URL(string: endpoint)?.host?.lowercased() ?? endpoint) }
    static func read(_ account: String, allowUI: Bool = true) throws -> String {
        var result: CFTypeRef?
        let context = LAContext(); context.interactionNotAllowed = !allowUI
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "io.github.rowanhfinch.sayvia.credentials", kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: context] as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw AppError("密钥仍在系统钥匙串中，但当前版本无权读取。请在系统提示中允许 Sayvia 访问，无需重新填写密钥（状态 \(status)）。") }
        return key
    }
    static func exists(_ account: String) throws -> Bool {
        let context = LAContext(); context.interactionNotAllowed = true
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "io.github.rowanhfinch.sayvia.credentials", kSecAttrAccount: account, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: context] as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AppError("钥匙串访问待授权，已有密钥会保留（状态 \(status)）。") }
        return true
    }
    static func write(_ key: String, account: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "io.github.rowanhfinch.sayvia.credentials", kSecAttrAccount: account] as [CFString: Any]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError("无法删除钥匙串凭据。") }; return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData] = data; item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError("无法保存 API Key 到钥匙串。") }
    }
}

// Never forward credentials through redirects, including redirects to another host.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
// URLSession cancellation must not keep the caller waiting for an uncooperative transport.
private final class RequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var outcome: Result<(Data, URLResponse), Error>?
    func start(_ continuation: CheckedContinuation<(Data, URLResponse), Error>, task: URLSessionDataTask) {
        lock.lock()
        if let outcome { lock.unlock(); task.cancel(); continuation.resume(with: outcome); return }
        self.continuation = continuation; self.task = task
        task.resume(); lock.unlock()
    }
    func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = continuation, task = task
        self.continuation = nil; self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }
}
struct ModelService {
    var configuration: Configuration
    var sttKey: String
    var rewriteKey: String
    var session: URLSession = ModelService.defaultSession
    var temporaryToken = false
    var maximumRecordingSeconds = 0
    // Reference for a realtime session, captured when recording starts.
    var realtimeTerms: [String] = []
    var realtimeContext = ""
    static let defaultSession = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    static var rewriteRulesURL: URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Sayvia_Sayvia.bundle") else { return nil }
            let url = Bundle(url: directory)?.url(forResource: "RewriteRules", withExtension: "json") ?? directory.appendingPathComponent("RewriteRules.json")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Bundle.module.url(forResource: "RewriteRules", withExtension: "json")
    }
    static func prepareRewriteRules() throws -> [String: String] {
        guard let url = rewriteRulesURL else { throw AppError("文字整理暂不可用，原文已保留。") }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
    static func endpoint(_ address: String) throws -> URL {
        guard !address.isEmpty else { throw AppError("请先在设置 → 服务里选择服务商，并填写 Workspace ID 或地址和 API Key。") }
        guard let url = URL(string: address), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw AppError("API 地址必须是无凭据、无查询参数的 HTTPS 完整端点。") }
        return url
    }
    func validate(needsAudio: Bool, needsRewrite: Bool = true) throws {
        try validateKeySeparation()
        if needsRewrite {
            _ = try Self.endpoint(configuration.rewriteURL)
            guard !rewriteKey.isEmpty, !configuration.rewriteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("请先配置整理模型与 API Key。") }
        }
        if needsAudio {
            _ = try Self.endpoint(configuration.sttURL)
            guard !sttKey.isEmpty, !configuration.sttModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("请先配置识别模型与 API Key。") }
            guard !configuration.sttModel.lowercased().contains("tts") else { throw AppError("TTS 是语音合成模型，请选择 ASR 语音识别模型。") }
        }
    }
    func validateKeySeparation() throws {
        if AssemblyStream.matches(configuration.sttURL), !sttKey.isEmpty, sttKey == rewriteKey {
            throw AppError("识别与整理来自不同服务，不能使用相同密钥。请重新复制各自的 API Key。")
        }
    }
    func send(url: String, key: String, data: Data, contentType: String, timeout: TimeInterval = 120, requestID: String? = nil, onTiming: (String) -> Void = { _ in }, onTrace: (ServiceTiming) -> Void = { _ in }) async throws -> Data {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("请先在设置中配置 API Key。") }
        let endpoint = try Self.endpoint(url)
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let started = ProcessInfo.processInfo.systemUptime
        var statusCode: Int?
        var outcome = "failed"
        defer { onTrace(ServiceTiming(stage: "client_request", start: started, end: ProcessInfo.processInfo.systemUptime, outcome: outcome, statusCode: statusCode, upstreamMS: nil, isRequest: true)) }
        let completion = RequestCompletion()
        let deadline = DispatchWorkItem { completion.finish(.failure(AppError("模型服务等待超时，原始内容已保存，可稍后重试。"))) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        let (body, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { completion.finish(.failure(error)) }
                    else if let data, let response { completion.finish(.success((data, response))) }
                    else { completion.finish(.failure(AppError("服务未返回有效响应。"))) }
                }
                completion.start(continuation, task: task)
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AppError("服务未返回有效响应。") }
        statusCode = response.statusCode
        let networkMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        onTiming("request_ms_\(networkMS)")
        guard (200..<300).contains(response.statusCode) else {
            // Inspect only a fixed error classification; never persist provider messages or response bodies.
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let failure = object["error"] as? [String: Any], failure["type"] as? String == "upstream_error" {
                throw AppError("模型供应商的上游服务不可用，原文已保留。请稍后重试或更换可用服务。")
            }
            throw AppError("模型服务返回 HTTP \(response.statusCode)。请检查端点、模型、额度与网络。")
        }
        guard body.count < 4_000_000 else { throw AppError("模型响应过大，已停止处理。") }
        outcome = "completed"
        return body
    }
    static func isBailianASR(_ address: String) -> Bool {
        guard let url = URL(string: address), let host = url.host else { return false }
        return (host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" || host.hasSuffix(".maas.aliyuncs.com")) && url.path == "/api/v1/services/aigc/multimodal-generation/generation"
    }
    func transcribe(audio: URL, terms: [String], context: String = "", onFinal: (@MainActor (String) -> Void)? = nil, onDiagnostic: (@MainActor (String) -> Void)? = nil, onTrace: (ServiceTiming) -> Void = { _ in }) async throws -> String {
        if AssemblyStream.matches(configuration.sttURL) {
            return try await AssemblyStream.transcribe(audio: audio, configuration: configuration, key: sttKey, terms: terms, temporaryToken: temporaryToken, onFinal: onFinal, onDiagnostic: onDiagnostic)
        }
        let encodingStarted = ProcessInfo.processInfo.systemUptime
        var encodingDone = false
        func finishEncoding(_ outcome: String = "completed") {
            guard !encodingDone else { return }; encodingDone = true
            onTrace(ServiceTiming(stage: "audio_encoding", start: encodingStarted, end: ProcessInfo.processInfo.systemUptime, outcome: outcome))
        }
        defer { if !encodingDone { finishEncoding("failed") } }
        let file = try Data(contentsOf: audio)
        guard !file.isEmpty, file.count <= 24_000_000 else { throw AppError("音频为空或超过 24 MB，无法上传。") }
        if Self.isBailianASR(configuration.sttURL) {
            let decoded = try AVAudioFile(forReading: audio)
            guard Double(decoded.length) / decoded.processingFormat.sampleRate <= 300 else { throw AppError("百炼短语音接口最多 5 分钟，音频已保留。") }
            let encoded = file.base64EncodedString()
            guard encoded.utf8.count <= 10_000_000 else { throw AppError("本机百炼 Base64 上传上限为 10 MB，音频已保留。") }
            let payload = Self.bailianPayload(configuration: configuration, audio: encoded, terms: terms, context: context)
            let requestData = try JSONSerialization.data(withJSONObject: payload); finishEncoding()
            let data = try await send(url: configuration.sttURL, key: sttKey, data: requestData, contentType: "application/json", onTrace: onTrace)
            struct Response: Decodable { struct Output: Decodable { let text: String }; let output: Output }
            let text = try JSONDecoder().decode(Response.self, from: data).output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AppError(AppError.noSpeech) }
            await onDiagnostic?("bailian_context_chars=\(min(context.count, 400)) dictionary_count=\(min(terms.count, 100))")
            return text
        }
        let boundary = "Sayvia-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        var fields = [("model", configuration.sttModel), ("response_format", "json")]
        if !configuration.language.isEmpty { fields.append(("language", configuration.language)) }
        if !terms.isEmpty || !context.isEmpty { fields.append(("prompt", String((terms.joined(separator: ", ") + "\n" + context).prefix(2000)))) }
        for (name, value) in fields { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n") }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(file); append("\r\n--\(boundary)--\r\n")
        struct Response: Decodable { let text: String }
        finishEncoding()
        let data = try await send(url: configuration.sttURL, key: sttKey, data: body, contentType: "multipart/form-data; boundary=\(boundary)", onTrace: onTrace)
        let text = try JSONDecoder().decode(Response.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppError(AppError.noSpeech) }
        return text
    }
    static func bailianPayload(configuration: Configuration, audio: String, terms: [String], context: String) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !context.isEmpty { messages.append(["role": "user", "content": [["type": "input_text", "text": String(context.prefix(400))]]]) }
        messages.append(["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "data:audio/mp4;base64," + audio]]]])
        var parameters: [String: Any] = ["format": "m4a"]
        if configuration.sttModel.hasPrefix("qwen-audio-3.") {
            parameters["vocabulary"] = Dictionary(terms.filter { !$0.isEmpty && $0.count <= 100 }.prefix(100).map { ($0, 3) }, uniquingKeysWith: { a, _ in a })
        }
        if !configuration.language.isEmpty { parameters["language_hints"] = [configuration.language] }
        return ["model": configuration.sttModel, "input": ["messages": messages], "parameters": parameters]
    }
    func rewrite(raw: String, context: String, preferences: [Preference], examples: [Correction], terms: [DictionaryEntry], onDiagnostic: (String) -> Void = { _ in }, onModelResult: (String) -> Void = { _ in }, preparedRules: [String: String]? = nil, onTrace: (ServiceTiming) -> Void = { _ in }) async throws -> String {
        try validateKeySeparation()
        // Packaged apps must read their own rules, never a compiled-in development path.
        let rules = try preparedRules ?? Self.prepareRewriteRules()
        guard let rule = rules["dictate"] else { throw AppError("文字整理暂不可用，原文已保留。") }
        let activeTerms = TermDictionary.active(terms, context: raw + "\n" + context)
        let input: [String: Any] = ["transcript": raw, "context": Safety.prefixUTF16(context, limit: 5000), "style_preferences": preferences.filter { $0.enabled && $0.instruction.utf16.count <= 1000 }.prefix(20).map(\.instruction), "dictionary": activeTerms.map { ["term": $0.term, "hint": $0.hint, "aliases": $0.aliases] as [String: Any] }, "examples": examples.filter { $0.enabled && $0.before.utf16.count <= 4000 && $0.after.utf16.count <= 4000 }.suffix(5).map { ["before": $0.before, "after": $0.after] }]
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        var payload: [String: Any]
        payload = ["model": configuration.rewriteModel, "messages": [["role": "system", "content": rule], ["role": "user", "content": serialized]], "stream": false, "max_tokens": 8000]
        // Cleanup is a fidelity task, not a reasoning task. Gemini 2.5 supports disabling thinking.
        if configuration.rewriteModel == "gemini-2.5-flash" { payload["reasoning_effort"] = "none" }
        if (configuration.rewriteModel.hasPrefix("qwen3") || ["qwen-flash", "qwen-plus", "qwen-turbo"].contains(configuration.rewriteModel)) { payload["enable_thinking"] = false }
        let requestData = try JSONSerialization.data(withJSONObject: payload)
        var timing = ""
        let data = try await send(url: configuration.rewriteURL, key: rewriteKey, data: requestData, contentType: "application/json", timeout: 15, onTiming: { timing = $0 }, onTrace: onTrace)
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        let choice = try JSONDecoder().decode(Response.self, from: data).choices.first
        guard choice?.finish_reason == nil || choice?.finish_reason == "stop" else { throw AppError("整理输出未完整结束，原始转写已保留；请在历史重试。") }
        let modelText = choice?.message.content ?? ""
        let text = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppError("整理服务未返回文字，原始转写已保留。") }
        onModelResult(modelText)
        guard Safety.keepsLanguage(raw: raw, result: text, terms: activeTerms) else { throw AppError("整理模型改变了原文语言，已拦截结果并保留原文。") }
        let result = Safety.cleanPronounStutters(text, raw: raw, protectedTerms: activeTerms.flatMap { [$0.term] + $0.aliases })
        guard Safety.keepsDecimalScale(raw: raw, result: result) else { throw AppError("整理结果可能丢失小数点、改变数值量级，已拦截结果并保留原文。") }
        guard Safety.keepsDetail(raw: raw, result: result) else { throw AppError("整理结果缩减过多，可能遗漏细节，已保留完整原文。") }
        onDiagnostic((text == raw.trimmingCharacters(in: .whitespacesAndNewlines) ? "model_unchanged" : "model_changed") + (result != text ? "+local_stutter_cleanup" : "") + ":" + timing)
        return result
    }
    // One cheap text call per captured correction. Only the changed spans with a
    // few words of context leave the Mac, never the whole field.
    func reviewCorrections(_ candidates: [CorrectionReview.Candidate]) async throws -> [CorrectionReview.Decision] {
        guard !candidates.isEmpty else { return [] }
        let items = candidates.prefix(CorrectionReview.maximumCandidates).enumerated().map { ["id": $0.offset, "originalText": $0.element.original, "correctedText": $0.element.corrected] as [String: Any] }
        try validateKeySeparation()
        guard let rule = try Self.prepareRewriteRules()["learn"] else { throw AppError("词典学习暂不可用。") }
        let user = String(decoding: try JSONSerialization.data(withJSONObject: ["candidates": items]), as: UTF8.self)
        var payload: [String: Any] = ["model": configuration.rewriteModel, "messages": [["role": "system", "content": rule], ["role": "user", "content": user]], "stream": false, "max_tokens": 1000]
        if configuration.rewriteModel.hasPrefix("qwen3") || ["qwen-flash", "qwen-plus", "qwen-turbo"].contains(configuration.rewriteModel) { payload["enable_thinking"] = false }
        let data = try await send(url: configuration.rewriteURL, key: rewriteKey, data: try JSONSerialization.data(withJSONObject: payload), contentType: "application/json", timeout: 15)
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        guard let choice = try JSONDecoder().decode(Response.self, from: data).choices.first, choice.finish_reason == nil || choice.finish_reason == "stop" else { throw AppError("词典学习未返回完整结果。") }
        return CorrectionReview.decisions(from: choice.message.content ?? "", candidates: Array(candidates.prefix(CorrectionReview.maximumCandidates)))
    }
}
