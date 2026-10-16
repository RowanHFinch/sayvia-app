import Foundation

// Realtime protocol core: PCM queue, sentence order and finals. BailianStream
// feeds it the supplier's events; only a complete final becomes completedText.
@MainActor final class BailianRealtimeCandidate {
    nonisolated static let blockedReason = "实时识别需要阿里云百炼和已保存的 API Key，音频已保留。"
    nonisolated static func requireChannel(_ service: ModelService?) throws {
        guard let service, service.configuration.realtime, !service.sttKey.isEmpty else { throw AppError(blockedReason) }
    }
    private let queue = StreamingPCMQueue(sampleRate: 16000)
    private var ready = false
    private var closing = false
    private var committed = false
    private var finishSent = false
    private(set) var status = "connecting"
    private(set) var inputBytes = 0
    private(set) var sentSegments = 0
    private var order: [String] = []
    private var finals: [String: String] = [:]
    private(set) var completedText: String?
    var finalizedText: String { order.compactMap { finals[$0] }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    private func message(_ type: String, fields: [String: Any] = [:]) throws -> Data {
        var value = fields; value["type"] = type; value["event_id"] = "event_" + UUID().uuidString
        return try JSONSerialization.data(withJSONObject: value)
    }
    func configurationMessage() throws -> Data {
        try message("session.update", fields: ["session": ["input_audio_format": "pcm", "sample_rate": 16000, "turn_detection": NSNull()]])
    }
    func appendPCM(_ data: Data) throws {
        guard !closing, !["cancelled", "failed", "completed"].contains(status) else { throw AppError("实时会话已结束，音频仍保留。") }
        guard data.count <= 16000 * 2 * 300 - inputBytes else { fail(); throw AppError("录音超过实时会话单次边界，音频仍保留。") }
        do { try queue.appendPCM(data); inputBytes += data.count }
        catch { fail(); throw error }
    }
    func finish() { guard !["cancelled", "failed", "completed"].contains(status) else { return }; closing = true; queue.finish() }
    func cancel() { guard status != "completed" else { return }; status = "cancelled"; queue.cancel(); completedText = nil; finals.removeAll() }
    func fail() { status = "failed"; queue.cancel(); completedText = nil }
    // The transport sends each returned frame once, in order; a send failure
    // calls fail() and never resends or replays the saved file automatically.
    func nextMessage() throws -> Data? {
        guard ready, !["cancelled", "failed", "completed"].contains(status), !finishSent else { return nil }
        if let pcm = try queue.drainPCM() {
            guard !pcm.isEmpty else { return nil }; sentSegments += 1
            return try message("input_audio_buffer.append", fields: ["audio": pcm.base64EncodedString()])
        }
        guard closing else { return nil }
        if !committed, inputBytes > 0 { committed = true; return try message("input_audio_buffer.commit") }
        finishSent = true; status = "finishing"; return try message("session.finish")
    }
    func receive(_ data: Data) throws {
        guard !["cancelled", "failed", "completed"].contains(status) else { return }
        do {
            guard data.count <= 1_000_000, let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { throw AppError("实时识别响应格式无效，音频仍保留。") }
            switch type {
            case "session.updated": ready = true; status = "streaming"
            case "input_audio_buffer.committed", "conversation.item.created":
                let id = (event["item_id"] as? String) ?? (event["item"] as? [String: Any])?["id"] as? String
                guard let id, !id.isEmpty, id.count <= 200 else { throw AppError("实时识别片段身份无效。") }
                if !order.contains(id) { guard order.count < 1000 else { throw AppError("实时识别片段过多。") }; order.append(id) }
            case "conversation.item.input_audio_transcription.completed":
                guard let id = event["item_id"] as? String, order.contains(id), let text = event["transcript"] as? String, text.utf16.count <= 20_000 else { throw AppError("实时识别终稿无效，音频仍保留。") }
                if let previous = finals[id], previous != text { throw AppError("实时识别返回相互矛盾的终稿，音频仍保留。") }
                finals[id] = text
                guard finalizedText.utf16.count <= 20_000 else { finals.removeValue(forKey: id); throw AppError("实时识别文字超过单次边界，音频仍保留。") }
            case "session.finished":
                guard finishSent, order.allSatisfy({ finals[$0] != nil }) else { throw AppError("实时连接提前结束或终稿缺失，音频仍保留。") }
                let text = finalizedText
                // A finished session without words is silence, not a broken connection.
                guard !text.isEmpty else { throw AppError(AppError.noSpeech) }
                guard text.utf16.count <= 20_000 else { throw AppError("实时识别没有完整文字，音频仍保留。") }
                completedText = text; status = "completed"
            case "error", "conversation.item.input_audio_transcription.failed": throw AppError("实时识别失败，音频仍保留；不会自动重传。")
            default: break // Partial text never becomes completedText or target input.
            }
        } catch { fail(); throw error }
    }
}
