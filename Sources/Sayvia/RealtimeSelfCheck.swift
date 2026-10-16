import Foundation
import AVFoundation

// Plays a scripted Bailian duplex session: records what the client sends and
// answers run-task / finish-task the way the supplier does.
@MainActor private final class FakeRealtimeSocket: RealtimeSocket {
    var sent: [URLSessionWebSocketTask.Message] = []
    var closed = false
    var onFinish: (String) -> [String] = { _ in [] }
    var taskID = ""
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        sent.append(message)
        guard case .string(let text) = message, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let header = value["header"] as? [String: Any], let action = header["action"] as? String else { return }
        if action == "run-task" { taskID = header["task_id"] as! String; push(event("task-started")) }
        if action == "finish-task" { onFinish(taskID).forEach(push) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !inbox.isEmpty { return .string(inbox.removeFirst()) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() { closed = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
    func push(_ text: String) { if let waiter { self.waiter = nil; waiter.resume(returning: .string(text)) } else { inbox.append(text) } }
    func event(_ name: String, sentence: [String: Any]? = nil) -> String {
        var value: [String: Any] = ["header": ["event": name, "task_id": taskID]]
        if let sentence { value["payload"] = ["output": ["sentence": sentence]] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, line: UInt = #line) { precondition(a == b, "Expected \(b), got \(a)", line: line) }
@MainActor private func expectFailure(line: UInt = #line, _ body: () async throws -> Any) async {
    do { _ = try await body(); preconditionFailure("Expected error", line: line) } catch {}
}

extension SafetyChecks {
    func testDirectRealtime() async throws {
        var configuration = Configuration(); configuration.sttURL = Provider.bailianBeijing.sttURL(workspace: "ws-fixture"); configuration.language = "zh"
        var service = ModelService(configuration: configuration, sttKey: "fixture-key", rewriteKey: "fixture-key")
        service.realtimeTerms = ["Sayvia"]; service.realtimeContext = "窗口：fixture"
        func run(_ socket: FakeRealtimeSocket, maxWait: TimeInterval = 20) async throws -> String {
            var chunks = 5
            let stream = try BailianStream(service: service, sampleRate: 16000, source: {
                guard chunks > 0 else { return nil }; chunks -= 1; return Data(count: 3200)
            }, socket: socket)
            return try await stream.result(maxWait: maxWait)
        }
        // Finals in order; partial text and heartbeats never reach the result.
        let socket = FakeRealtimeSocket()
        socket.onFinish = { _ in [
            socket.event("result-generated", sentence: ["sentence_id": 1, "sentence_end": false, "text": "你"]),
            socket.event("result-generated", sentence: ["heartbeat": true]),
            socket.event("result-generated", sentence: ["sentence_id": 1, "sentence_end": true, "text": "你好。"]),
            socket.event("result-generated", sentence: ["sentence_id": 2, "sentence_end": true, "text": "Sayvia 很快。"]),
            socket.event("task-finished")] }
        expectEqual(try await run(socket), "你好。 Sayvia 很快。")
        guard case .string(let start) = socket.sent.first, let runTask = try JSONSerialization.jsonObject(with: Data(start.utf8)) as? [String: Any],
              let payload = runTask["payload"] as? [String: Any], let parameters = payload["parameters"] as? [String: Any] else { throw AppError("run-task missing") }
        expectEqual(payload["model"] as? String, "qwen-audio-3.1-asr-flash-streaming")
        expectEqual(parameters["vocabulary"] as? [String: Int], ["Sayvia": 3]); expectEqual(parameters["language_hints"] as? [String], ["zh"])
        let audio = socket.sent.compactMap { if case .data(let data) = $0 { return data.count } else { return nil } }
        precondition(!audio.isEmpty && audio.allSatisfy { $0 >= 1600 && $0 <= 6400 }); expectEqual(audio.reduce(0, +) >= 16000, true)
        guard case .string(let finish) = socket.sent.last else { throw AppError("finish-task missing") }
        precondition(finish.contains("finish-task")); precondition(socket.closed)

        // A supplier failure fails the session; nothing is replayed.
        let failing = FakeRealtimeSocket(); failing.onFinish = { _ in [failing.event("task-failed")] }
        await expectFailure { try await run(failing) }; expectEqual(failing.sent.filter { if case .string = $0 { return true } else { return false } }.count, 2)

        // A stalled tail that never carried text is dropped after the wait; open text fails.
        let silent = FakeRealtimeSocket()
        silent.onFinish = { _ in [silent.event("result-generated", sentence: ["sentence_id": 1, "sentence_end": true, "text": "完整。"]),
                                  silent.event("result-generated", sentence: ["sentence_id": 2, "sentence_end": false, "text": ""])] }
        expectEqual(try await run(silent, maxWait: 0.2), "完整。")
        let open = FakeRealtimeSocket()
        open.onFinish = { _ in [open.event("result-generated", sentence: ["sentence_id": 1, "sentence_end": true, "text": "完整。"]),
                                open.event("result-generated", sentence: ["sentence_id": 2, "sentence_end": false, "text": "还没说完"])] }
        await expectFailure { try await run(open, maxWait: 0.2) }

        // Other providers never open a realtime session.
        var other = configuration; other.sttURL = Provider.openAI.sttURL(workspace: "")
        await expectFailure { _ = try BailianStream(service: ModelService(configuration: other, sttKey: "k", rewriteKey: "k"), sampleRate: 16000, source: { nil }, socket: FakeRealtimeSocket()) }
        print("PASS: direct Bailian realtime run-task/PCM/finish-task, ordered finals without partials, supplier failure without replay, silent-tail drop vs open text, non-Bailian blocked (offline fake socket)")
    }
}
