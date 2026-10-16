import AppKit
import Carbon
import AVFoundation
import ApplicationServices

private func goalEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
private func goalThrows(_ action: () throws -> Void) { do { try action(); preconditionFailure("Expected failure") } catch {} }
private func goalEvent(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

// Only the network is replaced. All persistence, cancellation, fidelity,
// focus locking, event construction and confirmation run in production code.
private final class GoalModelProtocol: URLProtocol, @unchecked Sendable {
    // No closing full stop: mid-text targets would drop it (fitPunctuation).
    static let raw = "星期六，不对，星期二联系张珊；金额 19.99 元，范围 12.50—15.75；不要发布，只在批准后使用 Qwen 与 Sayvia"
    private static let lock = NSLock()
    private static var payloads: [(String, [String: Any])] = []
    static func reset() { lock.lock(); payloads.removeAll(); lock.unlock() }
    static var requests: [(String, [String: Any])] { lock.lock(); defer { lock.unlock() }; return payloads }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "goal-fixture.sayvia.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        }
        let object = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
        Self.lock.lock(); Self.payloads.append((request.url!.path, object)); Self.lock.unlock()
        let audio = request.url!.path.contains("audio")
        let body = try! goalEvent(audio ? ["text": Self.raw] : ["choices": [["message": ["content": Self.raw], "finish_reason": "stop"]]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Server-Timing": "upstream;dur=3"])!
        DispatchQueue.global().asyncAfter(deadline: .now() + (audio ? 0.09 : 0.12)) {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body); self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension SafetyChecks {
    func testGoalTraceAndContextMetadata() throws {
        var clock = 10.0
        let trace = LatencyRecorder(origin: "stop_requested", stopTrigger: "user_control", now: { clock })
        let audio = trace.begin("audio_close"); clock += 0.012; trace.end(audio)
        let network = trace.begin("recognition_final"), context = trace.begin("rewrite_context_preparation")
        clock += 0.004; trace.end(context); clock += 0.024; trace.end(network)
        let snapshot = trace.snapshot()
        precondition(abs(snapshot.elapsedMS - 40) < 0.001)
        precondition(abs(snapshot.spans[0].durationMS! - 12) < 0.001)
        precondition(snapshot.lastSpeechToStopMS == nil)
        var old = Attempt(); old.raw = "offline fixture"
        let encoded = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(Attempt.self, from: encoded)
        precondition(decoded.trace == nil && decoded.delivery == nil && decoded.sttMS == nil)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy["sttMS"] = 153; legacy["rewriteMS"] = 0
        let legacyAttempt = try JSONDecoder().decode(Attempt.self, from: goalEvent(legacy))
        goalEqual(legacyAttempt.sttMS, 153); goalEqual(legacyAttempt.rewriteMS, 0)
        precondition(legacyAttempt.trace == nil && legacyAttempt.delivery == nil)
        var current = old; current.trace = snapshot; current.delivery = InputDeliveryEvidence(status: "pending", dispatchAttempted: nil)
        goalEqual(try JSONDecoder().decode(Attempt.self, from: JSONEncoder().encode(current)), current)
        goalEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(Configuration())).realtimeCandidate, nil)

        let field = AXUIElementCreateApplication(81), window = AXUIElementCreateApplication(82)
        for scenario in ["opaque", "marker_only", "cell", "timeout", "secure", "titled", "titled_text"] {
            let hooks = ContextCaptureHooks(allowed: { true }, query: { node, name in
                if CFEqual(node, window), name == kAXRoleAttribute { return (.success, kAXWindowRole as CFString) }
                if CFEqual(node, window), name == kAXTitleAttribute { return scenario.hasPrefix("titled") ? (.success, " 王祎 - 周报 " as CFString) : (.noValue, nil) }
                if name == kAXSelectedTextRangeAttribute, scenario == "titled_text" { var range = CFRange(location: 7, length: 0); return (.success, AXValueCreate(.cfRange, &range)) }
                if name == kAXFocusedUIElementAttribute { return CFEqual(node, field) ? (.noValue, nil) : (.success, field) }
                if name == kAXWindowAttribute { return (.success, window) }
                if name == kAXRoleAttribute { return (.success, (scenario == "cell" ? "AXGrid" : kAXTextAreaRole) as CFString) }
                if name == kAXSubroleAttribute { return (.success, (scenario == "secure" ? kAXSecureTextFieldSubrole : "") as CFString) }
                if name == kAXValueAttribute { return scenario == "timeout" ? (.cannotComplete, nil) : scenario == "opaque" ? (.attributeUnsupported, nil) : (.success, "fixture context" as CFString) }
                return (.attributeUnsupported, nil)
            }, pid: { _ in 81 }, appID: { _ in "fixture-app" })
            let reference = OptionalContextReader.capture(deadline: ProcessInfo.processInfo.systemUptime + 1, hooks: hooks)
            if ["timeout", "secure"].contains(scenario) { precondition(reference == nil) }
            else if scenario == "titled" { goalEqual(reference?.context, "应用：fixture-app\n窗口：王祎 - 周报") }
            else if scenario == "titled_text" { goalEqual(reference?.context, "应用：fixture-app\n窗口：王祎 - 周报\n" + Safety.nearbyText("fixture context", range: NSRange(location: 7, length: 0))) }
            else { goalEqual(reference?.appID, "fixture-app"); goalEqual(reference?.context, "") }
        }
        // Screen text: the rest of the window (or its web area) without the field itself or secure values.
        let page = AXUIElementCreateApplication(83), line = AXUIElementCreateApplication(84), secret = AXUIElementCreateApplication(85), toolbar = AXUIElementCreateApplication(86), masked = AXUIElementCreateApplication(87)
        for (webArea, slow) in [(false, false), (true, false), (true, true)] {
            let hooks = ContextCaptureHooks(allowed: { true }, query: { node, name in
                func role(_ value: String) -> (AXError, CFTypeRef?) { (.success, value as CFString) }
                if name == kAXFocusedUIElementAttribute { return CFEqual(node, field) ? (.noValue, nil) : (.success, field) }
                if CFEqual(node, field) {
                    switch name {
                    case kAXRoleAttribute: return role(kAXTextAreaRole)
                    case kAXWindowAttribute: return (.success, window)
                    case kAXParentAttribute: return (.success, webArea ? page : window)
                    case kAXValueAttribute: return role("draft")
                    case kAXSelectedTextRangeAttribute: var range = CFRange(location: 5, length: 0); return (.success, AXValueCreate(.cfRange, &range))
                    default: return (.attributeUnsupported, nil)
                    }
                }
                if CFEqual(node, window) {
                    if name == kAXRoleAttribute { return role(kAXWindowRole) }
                    if name == kAXTitleAttribute { return role("周报") }
                    if name == kAXChildrenAttribute { return (.success, [toolbar, page] as CFArray) }
                }
                if CFEqual(node, toolbar) { return name == kAXRoleAttribute ? role(kAXStaticTextRole) : name == kAXValueAttribute ? role("后退") : (.attributeUnsupported, nil) }
                if CFEqual(node, page) {
                    if name == kAXRoleAttribute { return role("AXWebArea") }
                    if name == kAXParentAttribute { return (.success, window) }
                    if name == kAXChildrenAttribute { if slow { Thread.sleep(forTimeInterval: 0.2) }; return (.success, [line, secret, field] as CFArray) }
                }
                if CFEqual(node, masked) { return name == kAXRoleAttribute ? role(kAXStaticTextRole) : name == kAXValueAttribute ? role("PRIVATE_CHILD") : (.attributeUnsupported, nil) }
                if CFEqual(node, line) { return name == kAXRoleAttribute ? role(kAXStaticTextRole) : name == kAXValueAttribute ? role(" 王祎：明天评审 ") : (.attributeUnsupported, nil) }
                if CFEqual(node, secret) {
                    switch name {
                    case kAXRoleAttribute: return role(kAXTextFieldRole)
                    case kAXSubroleAttribute: return role(kAXSecureTextFieldSubrole)
                    case kAXValueAttribute: return role("PRIVATE_SECRET")
                    case kAXChildrenAttribute: return (.success, [masked] as CFArray)
                    default: return (.attributeUnsupported, nil)
                    }
                }
                return (.attributeUnsupported, nil)
            }, pid: { _ in 81 }, appID: { _ in "fixture-app" })
            let base = "应用：fixture-app\n窗口：周报\n" + Safety.nearbyText("draft", range: NSRange(location: 5, length: 0))
            if !slow { goalEqual(OptionalContextReader.capture(deadline: ProcessInfo.processInfo.systemUptime + 1, hooks: hooks)?.context, base) }
            // A window too slow to walk in the remaining time keeps the checked title and nearby text.
            let screen = OptionalContextReader.capture(deadline: ProcessInfo.processInfo.systemUptime + (slow ? 0.25 : 1), hooks: hooks, visibleText: true)
            goalEqual(screen?.context, slow ? base : base + "\n屏幕文字：\n" + (webArea ? "" : "后退\n") + "王祎：明天评审")
            goalEqual(screen?.visibleCharacters, slow ? 0 : webArea ? 7 : 10)
            precondition(screen?.context.contains("PRIVATE") == false)
        }
        print("PASS: monotonic trace fixture audio_close=12ms context=4ms final=28ms elapsed=40ms; legacy JSON, unknown metrics and opaque/marker/cell application scope; window title in context; screen text from the window or its web area skips the field and secure values; hard AX errors and secure fields rejected")
    }

    func testGoalOptionalContextDeadline() async throws {
        let reader = OptionalContextReader(), started = ProcessInfo.processInfo.systemUptime
        let result = await reader.read(budget: 0.025, capture: { _ in
            Thread.sleep(forTimeInterval: 0.15)
            return ContextReference(appID: "fixture", context: "late fixture", identity: InputIdentity(pid: 1, window: 2, element: 3))
        })
        goalEqual(result.outcome, "deadline"); precondition(result.reference == nil)
        precondition(ProcessInfo.processInfo.systemUptime - started < 0.12)
        goalEqual(await reader.read(budget: 0.025, capture: { _ in nil }).outcome, "reader_busy")
        try await Task.sleep(nanoseconds: 180_000_000)
        goalEqual(await reader.read(budget: 0.1, capture: { _ in nil }).outcome, "unavailable")
        let cancelled = Task { await reader.read(budget: 1, capture: { _ in Thread.sleep(forTimeInterval: 0.1); return nil }) }
        await Task.yield(); cancelled.cancel()
        goalEqual(await cancelled.value.outcome, "cancelled")
        print("PASS: optional AX worker releases at budget, rejects backlog, discards late data and survives cancellation (no native AX IPC)")
    }

    func testGoalDeliveryEvidence() async throws {
        let text = String(repeating: "数字 19.99，姓名张珊，不要发布 🌍。\n", count: 4)
        let before = InputTarget(element: AXUIElementCreateApplication(1), pid: 1, appID: "fixture", value: "前后", range: NSRange(location: 1, length: 0), window: AXUIElementCreateApplication(2))
        let other = InputTarget(element: AXUIElementCreateApplication(3), pid: 1, appID: "fixture", value: "另一个框", range: NSRange(location: 0, length: 0), window: before.window)
        for scenario in ["preserved", "no_change", "partial", "before_switch", "capture_read_switch", "mid_switch", "cancel"] {
            var sent = 0, captures = 0, active = true
            let trace = LatencyRecorder(origin: "input_test")
            let delivery = await before.deliver(text, isValid: { active }, capture: {
                captures += 1
                if scenario == "before_switch", captures >= 2 { return other }
                if scenario == "capture_read_switch", captures >= 3 { return other }
                if scenario == "mid_switch", sent > 0 { return other }
                if scenario == "preserved", sent == Safety.textChunks(text).count * 2 {
                    return InputTarget(element: before.element, pid: before.pid, appID: before.appID, value: "前" + text + "后", range: NSRange(location: 1 + text.utf16.count, length: 0), window: before.window)
                }
                if scenario == "partial", sent > 0 {
                    return InputTarget(element: before.element, pid: before.pid, appID: before.appID, value: "前" + String(text.prefix(5)) + "后", range: before.range, window: before.window)
                }
                return before
            }, dispatch: { event in
                precondition(event.flags.isEmpty)
                goalEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
                goalEqual(event.getIntegerValueField(.eventSourceUserData), Hotkeys.insertionEventTag)
                sent += 1; if scenario == "cancel" { active = false }
            }, trace: trace)
            goalEqual(delivery.route, "pid_unicode")
            goalEqual(delivery.dispatchedSegments * 2, sent)
            if scenario == "preserved" { goalEqual(delivery.status, "inserted"); goalEqual(delivery.confirmation, "preserved_document") }
            else if ["before_switch", "capture_read_switch"].contains(scenario) {
                goalEqual(delivery.status, "saved_only"); goalEqual(delivery.dispatchAttempted, false); goalEqual(sent, 0)
                if scenario == "capture_read_switch" { goalEqual(delivery.failureStage, "pre_dispatch_focus") }
            }
            else { goalEqual(delivery.status, "input_unconfirmed"); goalEqual(delivery.confirmation, "none"); goalEqual(delivery.dispatchAttempted, true) }
            if ["mid_switch", "cancel"].contains(scenario) { goalEqual(sent, 2) }
            if scenario == "no_change" { goalEqual(delivery.failureReason, "no_observed_text_change") }
            precondition(trace.snapshot().spans.allSatisfy { $0.endMS != nil })
        }
        print("PASS: structured capture/one dispatch/confirmation, long-text partial interruption, unchanged AX body, same-app field switch and cancellation; zero retry or send-key events")
    }

    func testGoalTracedPipeline() async throws {
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [GoalModelProtocol.self]
        var config = Configuration(); config.sttURL = "https://goal-fixture.sayvia.test/audio"; config.rewriteURL = "https://goal-fixture.sayvia.test/rewrite"
        let service = ModelService(configuration: config, sttKey: "fixture", rewriteKey: "fixture", session: URLSession(configuration: settings))
        for scenario in ["success", "stop_origin", "context_change", "cache_invalidation", "intent_failure", "status_failure", "cancel_after_dispatch", "candidate_blocked"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            GoalModelProtocol.reset()
            let first = InputTarget(element: AXUIElementCreateApplication(1), pid: 1, appID: "fixture", value: "前后", range: NSRange(location: 1, length: 0), window: AXUIElementCreateApplication(2))
            let second = InputTarget(element: AXUIElementCreateApplication(3), pid: 3, appID: "other", value: "前后", range: first.range, window: AXUIElementCreateApplication(4))
            var focused: InputTarget? = first, serial: UInt64 = 1, sent = 0
            weak var owner: AppModel?
            let hooks = InputHooks(capture: { focused }, snapshot: { owner.map { HotkeySnapshot(generation: $0.hotkeys.snapshot.generation, serial: serial) } }, dispatch: { event in
                guard let model = owner else { preconditionFailure("Missing fixture") }
                if sent == 0 {
                    let durable = try! model.store!.load(Recording.self, kind: "recording").first!
                    goalEqual(durable.insertion, "unknown"); goalEqual(durable.text, GoalModelProtocol.raw)
                    goalEqual(durable.attempts.last?.delivery?.status, "pending")
                    precondition(durable.attempts.last?.delivery?.dispatchAttempted == nil)
                    goalEqual(durable.attempts.last?.delivery?.route, "pid_unicode")
                }
                precondition(event.flags.isEmpty); sent += 1
                if scenario == "cancel_after_dispatch", sent == 1 { model.cancel() }
                if sent == Safety.textChunks(GoalModelProtocol.raw).count * 2, let target = focused {
                    focused = InputTarget(element: target.element, pid: target.pid, appID: target.appID, value: "前" + GoalModelProtocol.raw + "后", range: NSRange(location: 1 + GoalModelProtocol.raw.utf16.count, length: 0), window: target.window)
                }
            }, beforeSave: { stage in
                if scenario == "intent_failure", stage == "save_dispatch_intent" { throw AppError("fixture save failure") }
                if scenario == "status_failure", stage == "save_final_status" { throw AppError("fixture save failure") }
            })
            let model = AppModel(root: root, service: service, monitorSystem: false, inputHooks: hooks); owner = model
            func preparePersonalization() {
                model.preferences = [Preference(instruction: "fixture global"), Preference(instruction: "fixture old app", scope: "fixture"), Preference(instruction: "fixture new app", scope: "other")]
                model.corrections = [Correction(recordingID: "fixture", attemptID: "fixture", before: "before", after: "after", scope: "fixture")]
            }
            if scenario == "candidate_blocked" { model.config.realtimeCandidate = true; model.config.sttURL = Provider.bailianBeijing.sttURL(workspace: "ws-fixture") }
            if scenario == "stop_origin" {
                preparePersonalization()
                try model.startRecording(captureAudio: { url, _ in
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                    let sink = try model.capture.start(url: url, deviceID: "", streaming: true, syntheticFormat: format)
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!; buffer.frameLength = 16000
                    buffer.floatChannelData![0].initialize(repeating: 0, count: 16000); sink.append(buffer)
                    return sink
                })
                model.finish()
            } else {
                var record = Recording(); record.audioName = "fixture.m4a"
                try Data([1]).write(to: model.store!.audioURL(record)!)
                try model.store!.save(record, kind: "recording", id: record.id); try model.refresh()
                preparePersonalization()
                model.process(record, kind: "initial", source: nil, autoInsert: true)
            }
            if ["context_change", "cache_invalidation"].contains(scenario) {
                for _ in 0..<100 {
                    if GoalModelProtocol.requests.contains(where: { $0.0.contains(scenario == "cache_invalidation" ? "audio" : "rewrite") }) { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                focused = second; serial += 1
                if scenario == "cache_invalidation" {
                    model.preferences[2].instruction = "fixture updated app"
                    model.corrections.append(Correction(recordingID: "fixture", attemptID: "fixture", before: "new before", after: "new after", scope: "other"))
                }
            }
            for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!model.busy)
            if scenario == "cancel_after_dispatch" { try await Task.sleep(nanoseconds: 60_000_000) }
            let saved = try model.store!.load(Recording.self, kind: "recording").first!, attempt = saved.attempts.last!
            if scenario == "candidate_blocked" { goalEqual(sent, 0); goalEqual(GoalModelProtocol.requests.count, 0); goalEqual(attempt.status, "failed") }
            else {
                goalEqual(GoalModelProtocol.requests.count, 2); goalEqual(attempt.raw, GoalModelProtocol.raw); goalEqual(attempt.result, GoalModelProtocol.raw)
                let rewriteRequest = GoalModelProtocol.requests.first(where: { $0.0.contains("rewrite") })!.1
                let messages = rewriteRequest["messages"] as! [[String: Any]], userContent = messages.last!["content"] as! String
                let input = try JSONSerialization.jsonObject(with: Data(userContent.utf8)) as! [String: Any]
                goalEqual(input["style_preferences"] as? [String], ["fixture global", scenario == "cache_invalidation" ? "fixture updated app" : "fixture old app"])
                let examples = input["examples"] as! [[String: Any]]
                goalEqual(examples.count, 1); goalEqual(examples[0]["before"] as? String, scenario == "cache_invalidation" ? "new before" : "before")
                if scenario == "intent_failure" { goalEqual(sent, 0); goalEqual(saved.insertion, "saved_only"); goalEqual(attempt.delivery?.failureStage, "persist_intent") }
                else if scenario == "status_failure" {
                    goalEqual(saved.insertion, "unknown"); goalEqual(attempt.delivery?.status, "pending"); precondition(attempt.delivery?.dispatchAttempted == nil)
                    let reopened = AppModel(root: root, service: service, monitorSystem: false)
                    let recovered = reopened.records.first!
                    goalEqual(recovered.insertion, "unknown"); goalEqual(recovered.attempts.last?.delivery?.status, "pending")
                    precondition(recovered.attempts.last?.delivery?.dispatchAttempted == nil)
                    goalEqual(recovered.text, GoalModelProtocol.raw)
                }
                else if scenario == "cancel_after_dispatch" { goalEqual(sent, 2); goalEqual(saved.insertion, "input_unconfirmed"); goalEqual(attempt.delivery?.dispatchedSegments, 1) }
                else {
                    goalEqual(saved.insertion, "inserted"); goalEqual(attempt.delivery?.dispatchedSegments, Safety.textChunks(GoalModelProtocol.raw).count)
                    if scenario == "context_change" { precondition(attempt.trace!.flags.contains("context_target_changed")); goalEqual(saved.targetApp, "other") }
                    if scenario == "cache_invalidation" { precondition(attempt.trace!.flags.contains("rewrite_context_cache_invalidated")); goalEqual(saved.targetApp, "other") }
                    precondition(attempt.trace!.spans.contains(where: { $0.stage == "asr.audio_encoding" && $0.endMS != nil }))
                    precondition(attempt.trace!.spans.contains(where: { $0.stage == "save_result_before_input" && $0.endMS != nil }))
                    goalEqual(attempt.trace!.spans.last?.stage, "save_trace_checkpoint"); precondition(attempt.trace!.spans.last?.endMS == nil)
                    precondition(attempt.trace!.requests.allSatisfy { $0.uploadMS == nil && $0.upstreamMS == nil })
                    if scenario == "stop_origin" {
                        goalEqual(attempt.trace?.origin, "stop_requested"); goalEqual(saved.duration, 1)
                        goalEqual(attempt.trace?.spans.first?.stage, "audio_close")
                        precondition(attempt.trace!.spans.first!.endMS! <= attempt.trace!.spans.first(where: { $0.stage == "recognition_context" })!.startMS)
                        let summary = attempt.trace!.spans.map { "\($0.stage)=\($0.durationMS.map { String(format: "%.1fms", $0) } ?? "unknown")" }.joined(separator: " ")
                        print("EVIDENCE: synthetic stop_requested elapsed=\(String(format: "%.1f", attempt.trace!.elapsedMS))ms " + summary)
                    }
                }
            }
            precondition(FileManager.default.fileExists(atPath: model.store!.audioURL(saved)!.path))
            if scenario == "success" {
                model.edit(saved, text: "manual fixture")
                let edited = try model.store!.load(Recording.self, kind: "recording").first!
                goalEqual(edited.attempts.last?.kind, "edit"); precondition(edited.attempts.last?.trace == nil && edited.attempts.last?.delivery == nil)
                model.retry(edited, kind: "rewrite")
                for _ in 0..<200 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
                precondition(!model.busy)
                let retried = try model.store!.load(Recording.self, kind: "recording").first!
                goalEqual(retried.attempts.last?.trace?.origin, "history_retry"); goalEqual(sent, Safety.textChunks(GoalModelProtocol.raw).count * 2)
            }
            model.cancel()
        }
        print("PASS: production pipeline durable result/unknown intent precede first event, stage evidence, context/configuration cache invalidation with current app preferences/examples, manual-edit trace isolation, history retry without input, intent/final-save failures, cancelled partial dispatch, final-status honesty and blocked candidate with zero model calls; synthetic fidelity retained")
    }

    func testGoalFixedInputEvidence() async throws {
        GoalModelProtocol.reset()
        func startFixtureRecording(_ model: AppModel) throws {
            try model.startRecording(captureAudio: { url, _ in
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                let sink = try model.capture.start(url: url, deviceID: "", syntheticFormat: format)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!; buffer.frameLength = 160
                buffer.floatChannelData![0].initialize(repeating: 0, count: 160); sink.append(buffer)
                return sink
            }, connect: { throw AppError("fixture service must not connect") })
        }
        for scenario in ["inspect_success", "inspect_failure", "cancel_after_dispatch", "success", "capture_failure", "new_test_then_cancel", "new_recording"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let target = InputTarget(element: AXUIElementCreateApplication(1), pid: 1, appID: "fixture", value: "前后", range: NSRange(location: 1, length: 0), window: AXUIElementCreateApplication(2))
            var sent = 0
            weak var owner: AppModel?
            let hooks = InputHooks(capture: {
                if ["capture_failure", "inspect_failure"].contains(scenario) { return nil }
                if sent == Safety.textChunks(GoalModelProtocol.raw).count * 2 {
                    return InputTarget(element: target.element, pid: target.pid, appID: target.appID, value: "前" + GoalModelProtocol.raw + "后", range: NSRange(location: 1 + GoalModelProtocol.raw.utf16.count, length: 0), window: target.window)
                }
                return target
            }, snapshot: { owner.map { HotkeySnapshot(generation: $0.hotkeys.snapshot.generation, serial: 1) } }, dispatch: { event in
                precondition(event.flags.isEmpty); goalEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
                sent += 1
                if sent == 1, ["cancel_after_dispatch", "new_test_then_cancel", "new_recording"].contains(scenario) {
                    let model = owner!
                    model.cancel()
                    if scenario == "new_test_then_cancel" {
                        model.testInput(inspectOnly: true)
                        model.cancel()
                    } else if scenario == "new_recording" {
                        try! startFixtureRecording(model)
                        model.cancel()
                    }
                }
            })
            let model = AppModel(root: root, monitorSystem: false, inputHooks: hooks); owner = model
            var visibleOnCompletion = false
            model.onActivityChange = {
                if let model = owner, model.phase == "idle" { visibleOnCompletion = model.resultVisibleUntil > Date() }
            }
            model.testInput(text: GoalModelProtocol.raw, inspectOnly: scenario.hasPrefix("inspect_"))
            goalEqual(model.message, "\(scenario.hasPrefix("inspect_") ? "仅检查位置" : "输入测试") · 8 秒后")
            for _ in 0..<1100 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            try await Task.sleep(nanoseconds: 50_000_000)
            precondition(!model.busy)
            let evidence = model.inputTestEvidence
            if scenario.hasPrefix("inspect_") {
                goalEqual(sent, 0); precondition(visibleOnCompletion)
                precondition(model.lastPositionCheck.hasPrefix("上次位置检查 · "))
                precondition(model.lastPositionCheck.hasSuffix(model.inputTestResult))
                if scenario == "inspect_success" { goalEqual(evidence?.status, "inspect_only"); goalEqual(model.message, "位置已确认（未写入）") }
                else { goalEqual(evidence?.failureStage, "final_capture"); goalEqual(evidence?.dispatchAttempted, false); goalEqual(model.message, "位置无法确认（未写入）") }
                let inspection = model.lastPositionCheck
                model.testInput(inspectOnly: true); model.cancel()
                try await Task.sleep(nanoseconds: 20_000_000)
                goalEqual(model.lastPositionCheck, inspection); goalEqual(model.inputTestResult, "")
                if scenario == "inspect_success" { try startFixtureRecording(model); model.cancel() }
                goalEqual(model.lastPositionCheck, inspection); goalEqual(model.inputTestResult, ""); goalEqual(sent, 0)
            } else if scenario == "cancel_after_dispatch" {
                goalEqual(sent, 2); goalEqual(evidence?.status, "input_unconfirmed")
                goalEqual(evidence?.dispatchedSegments, 1); goalEqual(evidence?.dispatchAttempted, true)
                precondition(model.message.hasPrefix("已取消"))
            } else if scenario == "success" {
                goalEqual(evidence?.status, "inserted"); goalEqual(sent, Safety.textChunks(GoalModelProtocol.raw).count * 2)
                goalEqual(evidence?.confirmation, "preserved_document")
            } else if scenario == "capture_failure" {
                goalEqual(sent, 0); goalEqual(evidence?.failureStage, "final_capture"); goalEqual(evidence?.dispatchAttempted, false)
            } else {
                goalEqual(sent, 2); precondition(evidence == nil); goalEqual(model.inputTestResult, "")
                precondition(model.message.hasPrefix("已取消"))
            }
            let records = try model.store!.load(Recording.self, kind: "recording")
            goalEqual(records.count, ["new_recording", "inspect_success"].contains(scenario) ? 1 : 0)
            if let recorded = records.first {
                goalEqual(recorded.attempts.last?.status, "cancelled")
                precondition(recorded.attempts.last?.trace == nil && recorded.attempts.last?.delivery == nil)
                goalEqual(recorded.text, "")
                precondition(FileManager.default.fileExists(atPath: model.store!.audioURL(recorded)!.path))
            }
            goalEqual(GoalModelProtocol.requests.count, 0)
        }
        print("PASS: fixed-input entry shows countdown immediately and retains success/failure feedback; read-only checks never dispatch and survive later recording with dated metadata; cancelled owners and new tests/recordings remain isolated, no model or native dispatch")
    }

    // Uses a private named pasteboard; the real clipboard is never touched.
    @MainActor func testClipboardPaste() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("io.github.rowanhfinch.sayvia.selftest." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        let original = NSPasteboardItem(); original.setString("sk-original-secret", forType: .string); original.setData(Data([1, 2, 3]), forType: .png)
        precondition(board.writeObjects([original]))
        let saved = ClipboardPaste.snapshot(board)!
        precondition(!ClipboardPaste.concealed(saved))
        let session = ClipboardPaste.begin("听写结果", saved: saved, to: board)!
        precondition(ClipboardPaste.begin("again", saved: saved, to: board) == nil, "one pending paste at a time")
        goalEqual(session.provider.reads, 0)
        goalEqual(board.string(forType: .string), "听写结果"); goalEqual(session.provider.reads, 1)
        precondition(board.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != nil)
        // An early reader (here: this check) cannot shorten the minimum wait after Command-V.
        let waitStarted = ProcessInfo.processInfo.systemUptime
        goalEqual(await ClipboardPaste.finish(session, to: board, posted: true), "restored")
        precondition(ProcessInfo.processInfo.systemUptime - waitStarted >= ClipboardPaste.minWait)
        goalEqual(board.string(forType: .string), "sk-original-secret"); goalEqual(board.data(forType: .png), Data([1, 2, 3]))
        precondition(board.string(forType: ClipboardPaste.sessionType) == nil && ClipboardPaste.pending == nil)
        // A copy made by the user during the wait is never overwritten.
        let second = ClipboardPaste.begin("第二次", saved: ClipboardPaste.snapshot(board)!, to: board)!
        board.clearContents(); board.setString("user-new-copy", forType: .string)
        goalEqual(ClipboardPaste.restore(second, to: board), "skipped_newer_copy")
        goalEqual(board.string(forType: .string), "user-new-copy")
        // A copy between snapshot and write is never cleared.
        let stale = ClipboardPaste.snapshot(board)!; board.clearContents(); board.setString("copied-meanwhile", forType: .string)
        precondition(ClipboardPaste.begin("x", saved: stale, to: board) == nil); goalEqual(board.string(forType: .string), "copied-meanwhile")
        // Quit restores a pending paste; an empty clipboard is restored empty.
        board.clearContents()
        _ = ClipboardPaste.begin("x", saved: ClipboardPaste.snapshot(board)!, to: board)!
        ClipboardPaste.restorePending(board); precondition(board.string(forType: .string) == nil && ClipboardPaste.pending == nil)
        board.clearContents(); board.setString("password", forType: .string); board.setData(Data(), forType: ClipboardPaste.concealedType)
        precondition(ClipboardPaste.concealed(ClipboardPaste.snapshot(board)!))
        var posted: [CGEvent] = []
        precondition(ClipboardPaste.commandV(pid: 1, keyCode: 47, post: { posted.append($0) }))
        goalEqual(posted.count, 2); precondition(posted.allSatisfy { $0.flags.contains(.maskCommand) && $0.getIntegerValueField(.keyboardEventKeycode) == 47 && $0.getIntegerValueField(.eventSourceUserData) == Hotkeys.insertionEventTag })
        // Text controls paste first through the temporary clipboard, then restore;
        // a concealed (password manager) clipboard keeps the text-event route.
        let element = AXUIElementCreateApplication(931), window = AXUIElementCreateApplication(932)
        let opaque = InputTarget(element: element, pid: 1, appID: "fixture", value: "", range: NSRange(location: 0, length: 0), window: window, readsText: false, readsSelection: false)
        board.clearContents(); board.setString("user-copy", forType: .string)
        var events: [CGEvent] = [], pasteSession: ClipboardPaste.Session?
        let pastedEvidence = await opaque.deliver("粘贴结果", isValid: { true }, capture: { opaque }, dispatch: { events.append($0) }, pasteboard: board, onPasteSession: { session, sent in precondition(sent); pasteSession = session })
        goalEqual(pastedEvidence.route, "paste_restore"); goalEqual(pastedEvidence.status, "input_dispatched"); goalEqual(pastedEvidence.dispatchedSegments, 1)
        precondition(events.count == 2 && events.allSatisfy { $0.flags.contains(.maskCommand) })
        goalEqual(board.string(forType: .string), "粘贴结果")
        goalEqual(ClipboardPaste.restore(pasteSession!, to: board), "restored"); goalEqual(board.string(forType: .string), "user-copy")
        board.clearContents(); board.setString("password", forType: .string); board.setData(Data(), forType: ClipboardPaste.concealedType)
        events = []
        let typedEvidence = await opaque.deliver("文字事件", isValid: { true }, capture: { opaque }, dispatch: { events.append($0) }, pasteboard: board, onPasteSession: { _, _ in preconditionFailure("concealed clipboard must not be borrowed") })
        goalEqual(typedEvidence.route, "pid_unicode"); precondition(typedEvidence.checkpoints.contains("paste_skipped_clipboard_concealed"))
        goalEqual(board.string(forType: .string), "password"); precondition(ClipboardPaste.pending == nil)
        // Readback that saw the text returns the clipboard without the unread floor.
        board.clearContents(); board.setString("user-copy", forType: .string)
        let landed = ClipboardPaste.begin("已送达", saved: ClipboardPaste.snapshot(board)!, to: board)!
        landed.provider.landed = true
        let landedStarted = ProcessInfo.processInfo.systemUptime
        goalEqual(await ClipboardPaste.finish(landed, to: board, posted: true), "restored")
        precondition(ProcessInfo.processInfo.systemUptime - landedStarted < ClipboardPaste.minWait); goalEqual(board.string(forType: .string), "user-copy")
        // A copied image is not snapshotted on every dictation.
        board.clearContents(); board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let media = await opaque.deliver("图片剪贴板", isValid: { true }, capture: { opaque }, dispatch: { _ in }, pasteboard: board, onPasteSession: { _, _ in preconditionFailure("media clipboard must not be borrowed") })
        goalEqual(media.route, "pid_unicode"); precondition(media.checkpoints.contains("paste_skipped_clipboard_media"))
        // Command-V follows the layout's Command layer, read from system layouts.
        func layout(_ id: String) -> Data? {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let source = list.first,
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        }
        let command = UInt32((cmdKey >> 8) & 0xFF)
        for (id, code) in [("com.apple.keylayout.US", 9), ("com.apple.keylayout.Dvorak", 47), ("com.apple.keylayout.DVORAK-QWERTYCMD", 9)] {
            if let data = layout(id) { goalEqual(ClipboardPaste.keyCode(for: "v", layout: data, modifiers: command), CGKeyCode(code)) }
        }
        precondition(layout("com.apple.keylayout.Dvorak") != nil, "Dvorak layout fixture missing")
        for reason in ["non_text_target:com.example.chat:AXButton", "input_control_unavailable:focus_frontmost_application:AXFocusedUIElement:-25212", "invalid_marker_index", "selected_markers_outside_element:candidate_pid_722:candidate_app_com.example.messenger"] { precondition(ClipboardPaste.eligible(reason), reason) }
        for reason in ["secure_input_active", "secure_text_field", "capture_deadline:no_input_target", "focus_search_deadline", "AXFocusedUIElement:-25204", "non_text_target:com.microsoft.Excel:AXLayoutArea", "non_text_target:com.Snipaste:AXWindow", "non_text_target:com.apple.finder:AXScrollArea:editable_unknown:writable_selection_no:marker_focus_no_selection_markers:candidate_pid_726:candidate_app_com.apple.finder", "non_text_target:com.apple.Keynote:AXImage", "cell_selection_missing_or_multiple", "interaction_type_1", "capture_interaction_race", "sayvia_is_focused", "accessibility_not_trusted", "no_input_target"] { precondition(!ClipboardPaste.eligible(reason), reason) }
    }
    func testGoalStreamAndClipboardCandidates() async throws {
        for rate in [16000.0, 24000, 44100, 48000] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
            let converter = try StreamingPCMResampler(format: format)
            var pcm = Data(), remaining = Int(rate / 10)
            while remaining > 0 {
                let count = min(137, remaining), buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<2 { for frame in 0..<count { buffer.floatChannelData![channel][frame] = 0.1 } }
                pcm.append(try converter.appendPCM(buffer)); remaining -= count
            }
            pcm.append(try converter.finish()); goalEqual(pcm.count, 3200); goalEqual(try converter.finish().count, 0)
            let tailConverter = try StreamingPCMResampler(format: format)
            var tailPCM = Data(); remaining = Int(rate / 10)
            while remaining > 0 {
                let count = min(137, remaining), buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<2 { for frame in 0..<count { buffer.floatChannelData![channel][frame] = remaining - frame <= 12 ? 0.8 : 0 } }
                tailPCM.append(try tailConverter.appendPCM(buffer)); remaining -= count
            }
            tailPCM.append(try tailConverter.finish()); goalEqual(tailPCM.count, 3200)
            let samples = tailPCM.withUnsafeBytes { bytes in stride(from: 0, to: bytes.count, by: 2).map { Int(bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self)) } }
            precondition(samples.prefix(100).allSatisfy { abs($0) <= 1 })
            // The final 12 input frames carry speech. A count-only assertion
            // missed .none priming pushing almost all that energy beyond EOF.
            precondition(samples.suffix(64).map { abs($0) }.max()! > 12_000)
        }
        let queue = StreamingPCMQueue(sampleRate: 16000, bufferSeconds: 0.1)
        try queue.appendPCM(Data([1, 2])); queue.finish()
        let tail = try queue.drainPCM()!; goalEqual(tail.count, 1600); goalEqual(Array(tail.prefix(2)), [1, 2]); precondition(tail.dropFirst(2).allSatisfy { $0 == 0 }); let drained = try queue.drainPCM(); precondition(drained == nil)
        let overflow = StreamingPCMQueue(sampleRate: 16000, bufferSeconds: 0.1)
        goalThrows { try overflow.appendPCM(Data(count: 3202)) }; overflow.finish(); goalThrows { _ = try overflow.drainPCM() }
        let sinkURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: sinkURL) }
        let badFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: true)!
        let sink = try AudioSink(url: sinkURL, format: badFormat); sink.enableStreaming()
        let invalid = AVAudioPCMBuffer(pcmFormat: badFormat, frameCapacity: 160)!; invalid.frameLength = 160
        invalid.floatChannelData![0].initialize(repeating: 0, count: 320); sink.append(invalid); sink.close()
        goalThrows { _ = try sink.drainPCM() }
        precondition(FileManager.default.fileExists(atPath: sinkURL.path))

        let stream = BailianRealtimeCandidate()
        try stream.appendPCM(Data(count: 2000)); stream.finish(); stream.finish()
        let beforeReady = try stream.nextMessage(); precondition(beforeReady == nil)
        try stream.receive(goalEvent(["type": "session.updated"]))
        var types: [String] = []
        while let message = try stream.nextMessage() { types.append((try JSONSerialization.jsonObject(with: message) as! [String: Any])["type"] as! String) }
        goalEqual(types, ["input_audio_buffer.append", "input_audio_buffer.commit", "session.finish"])
        try stream.receive(goalEvent(["type": "input_audio_buffer.committed", "item_id": "fixture-1"]))
        try stream.receive(goalEvent(["type": "conversation.item.input_audio_transcription.text", "item_id": "fixture-1", "text": "partial fixture"]))
        precondition(stream.completedText == nil)
        let final = try goalEvent(["type": "conversation.item.input_audio_transcription.completed", "item_id": "fixture-1", "transcript": GoalModelProtocol.raw])
        try stream.receive(final); try stream.receive(final); precondition(stream.completedText == nil)
        try stream.receive(goalEvent(["type": "session.finished"])); goalEqual(stream.completedText, GoalModelProtocol.raw)
        let cancelled = BailianRealtimeCandidate(); cancelled.cancel(); try cancelled.receive(final); precondition(cancelled.completedText == nil)
        let disconnected = BailianRealtimeCandidate(); goalThrows { try disconnected.receive(try goalEvent(["type": "session.finished"])) }; goalEqual(disconnected.status, "failed")
        let conflicting = BailianRealtimeCandidate()
        try conflicting.receive(goalEvent(["type": "input_audio_buffer.committed", "item_id": "fixture-1"]))
        try conflicting.receive(final)
        goalThrows { try conflicting.receive(try goalEvent(["type": "conversation.item.input_audio_transcription.completed", "item_id": "fixture-1", "transcript": "contradictory fixture"])) }
        let oversized = BailianRealtimeCandidate(), firstSentence = String(repeating: "字", count: 10_000)
        for id in ["first", "second"] { try oversized.receive(goalEvent(["type": "conversation.item.created", "item_id": id])) }
        try oversized.receive(goalEvent(["type": "conversation.item.input_audio_transcription.completed", "item_id": "first", "transcript": firstSentence]))
        goalThrows { try oversized.receive(try goalEvent(["type": "conversation.item.input_audio_transcription.completed", "item_id": "second", "transcript": firstSentence])) }
        goalEqual(oversized.finalizedText, firstSentence); goalEqual(oversized.status, "failed"); precondition(oversized.completedText == nil)
        goalThrows { try BailianRealtimeCandidate.requireChannel(nil) }

        var version = 1
        let clipboardTypes = [["public.utf8-plain-text", "public.rtf"], ["public.png"]]
        let snapshot = ClipboardSnapshot.capture(changeCount: { version }, itemTypes: { clipboardTypes }, read: { item, type in Data("fixture-\(item)-\(type)".utf8) })!
        goalEqual(snapshot.items.count, 2); goalEqual(snapshot.items[0].representations.count, 2)
        precondition(ClipboardSnapshot.capture(changeCount: { version }, itemTypes: { clipboardTypes }, read: { _, _ in nil }) == nil)
        precondition(ClipboardSnapshot.capture(changeCount: { version }, itemTypes: { clipboardTypes }, read: { _, _ in version += 1; return Data() }) == nil)
        try await testClipboardPaste()
        print("PASS: 16/24/44.1/48kHz streaming resample EOF and final speech energy, short tail, bounded backpressure and conversion failure; Manual protocol final dedupe/conflict/disconnect/cancel; full multiformat clipboard snapshot and version rejection; temporary paste restores the original clipboard and yields to a newer copy")
    }
}
