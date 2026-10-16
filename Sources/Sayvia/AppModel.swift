import AppKit
import AVFoundation
import Carbon
import SwiftUI

// Offline pipeline checks substitute system focus and collect events here;
// normal app instances always use the native capture, listener and dispatcher.
struct InputHooks {
    let capture: () -> InputTarget?
    let snapshot: () -> HotkeySnapshot?
    let dispatch: (CGEvent) -> Void
    var setAttribute: ((AXUIElement, String, String) -> AXError)? = nil
    var beforeSave: ((String) throws -> Void)? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [Recording] = []
    @Published var dictionary: [DictionaryEntry] = [] { didSet { referenceRevision &+= 1 } }
    @Published var preferences: [Preference] = [] { didSet { referenceRevision &+= 1 } }
    @Published var corrections: [Correction] = [] { didSet { referenceRevision &+= 1 } }
    @Published var config = Configuration() { didSet { referenceRevision &+= 1 } }
    @Published var phase = "idle" { didSet {
        if phase != oldValue { phaseStarted = ProcessInfo.processInfo.systemUptime; processingSeconds = 0; hotkeys.escapeArmed = phase != "idle"; onActivityChange?() }
    } }
    @Published var message = "按 Fn 开始说话"
    @Published var resultVisibleUntil = Date.distantPast { didSet { onActivityChange?() } }
    @Published var error: String?
    @Published var elapsed: Double = 0
    @Published var volume: Double = 0
    @Published var processingSeconds = 0
    @Published var page = "首页"
    @Published var showSettings = false
    @Published var storeReady = false
    @Published var inputTestResult = ""
    @Published var inputTestEvidence: InputDeliveryEvidence?
    @Published private(set) var lastPositionCheck = ""
    @Published var recoveryText = ""
    // The last automatically learned term, offered for undo on the voice bar.
    @Published var learnedTerm: String?
    private var learnedCorrectionID: String?
    // Undo of the last toast restores automatic words it extended and blocks the words it created.
    private var learnedRestore: [DictionaryEntry] = [], learnedCreated: [String] = []
    // The model review of the latest correction; self-checks await it.
    private(set) var learningReview: Task<Void, Never>?
    // Seconds before the automatic stop, shown only during the last 30 seconds.
    @Published var recordingRemaining: Int?
    @Published var focusMonitoring = "焦点监听待命"
    private(set) var store: Store?
    let capture = AudioCapture()
    let hotkeys = Hotkeys()
    private let focusObserver = FocusObserver()
    private var timer: Timer?
    private var maintenance: Timer?
    private var work: Task<Void, Never>?
    private var streaming: AssemblyStream?
    private var realtime: BailianStream?
    private var recordingSink: AudioSink?
    private var recordingOwner: UUID?
    private var recordingService: ModelService?
    private var serviceConnection: Task<ModelService, Error>?
    let monitorSystem: Bool
    private let serviceOverride: ModelService?
    private let modelSession: URLSession
    private let inputHooks: InputHooks?
    private var generation = UUID()
    private var referenceRevision: UInt64 = 0
    private var focusRevision: UInt64 = 0
    private var sessionTrace: LatencyRecorder?
    private var traceRecordingID: String?
    private var inputTestID: UUID?
    private var activeID: String?
    private var target: InputTarget?
    private var targetInvalid = false
    private var targetInvalidReason: String?
    private var targetHotkeySnapshot: HotkeySnapshot?
    private var accessibilityRequests: [pid_t: (app: NSRunningApplication, time: Double)] = [:]
    private var observation: (target: InputTarget, text: String, prefix: String, suffix: String, recordID: String, attemptID: String, deadline: Date, last: String, changedAt: Date, edited: Bool)?
    // Judge an edit once the user pauses, presses Return or leaves the field.
    private let learningSettle: TimeInterval = 2
    private var player: AVAudioPlayer?
    var onActivityChange: (() -> Void)?
    private var phaseStarted = ProcessInfo.processInfo.systemUptime
    var busy: Bool { phase != "idle" }
    private struct ContextKey: Equatable {
        var focus: UInt64
        var interaction: HotkeySnapshot?
        var configuration: UInt64
    }
    private struct PreparedContext {
        var key: ContextKey
        var reference: ContextReference?
        var preferences: [Preference] = []
        var examples: [Correction] = []
    }
    private func contextKey() -> ContextKey {
        ContextKey(focus: focusRevision, interaction: currentInputSnapshot(), configuration: referenceRevision)
    }
    private func prepareContext(stage: String, trace: LatencyRecorder, visibleText: Bool = false) async -> PreparedContext {
        let key = contextKey(), span = trace.begin(stage)
        let result: ContextPreparationResult
        if let inputHooks {
            let focused = inputHooks.capture()
            result = ContextPreparationResult(reference: focused.map { ContextReference(appID: $0.appID, context: $0.context, identity: $0.identity) }, outcome: focused == nil ? "unavailable" : "prepared")
        } else if monitorSystem {
            let visibleText = visibleText && config.screenContext != false
            result = await OptionalContextReader.shared.read(budget: visibleText ? 0.5 : 0.12, visibleText: visibleText)
        }
        else { result = ContextPreparationResult(outcome: "disabled") }
        let valid = !Task.isCancelled && key == contextKey() && result.outcome == "prepared"
        trace.end(span, outcome: key != contextKey() ? "stale" : result.outcome)
        if !valid { trace.flag(stage + "_" + (key != contextKey() ? "stale" : result.outcome)) }
        let reference = valid ? result.reference : nil
        if let chars = reference?.visibleCharacters, chars > 0 { trace.flag(stage + "_screen_text_" + (chars < 500 ? "lt500" : chars < 2000 ? "lt2000" : "2000")) }
        let app = reference?.appID ?? ""
        let personalization = trace.begin("personalization_preparation")
        let prefs = preferences.filter { $0.enabled && ($0.scope.isEmpty || $0.scope == app) }
        let examples = corrections.filter { $0.enabled && !$0.scope.isEmpty && $0.scope == app }
        trace.end(personalization)
        return PreparedContext(key: key, reference: reference, preferences: prefs, examples: examples)
    }

    init(root: URL? = nil, service: ModelService? = nil, monitorSystem: Bool = true, inputHooks: InputHooks? = nil, modelSession: URLSession = ModelService.defaultSession) {
        self.monitorSystem = monitorSystem
        serviceOverride = service
        self.modelSession = modelSession
        self.inputHooks = inputHooks
        do {
            let store = try Store(root: root); self.store = store
            config = try store.load(Configuration.self, kind: "configuration").first ?? Configuration()
            try store.recover(); try store.seedDictionary(); try store.clearLegacyLearnedHints(); try refresh(); storeReady = true; maintain()
        } catch { self.error = error.localizedDescription }
        hotkeys.useFn = config.useFn
        hotkeys.escape = { [weak self] in self?.cancel() }
        hotkeys.action = { [weak self] snapshot in
            guard let self, snapshot.generation == self.hotkeys.snapshot.generation else { return }
            self.toggle()
        }
        hotkeys.interaction = { [weak self] type, key, flags, snapshot in
            guard let self else { return }
            guard snapshot.generation == self.hotkeys.snapshot.generation else { return }
            if self.phase == "inserting",
               let baseline = self.targetHotkeySnapshot, snapshot.invalidates(baseline, current: self.currentInputSnapshot() ?? self.hotkeys.snapshot) {
                self.invalidateTarget("interaction_type_\(type.rawValue)")
            }
            if self.observation != nil, let baseline = self.targetHotkeySnapshot,
               !snapshot.invalidates(baseline, current: self.currentInputSnapshot() ?? self.hotkeys.snapshot) { return }
            // Return (also ⌘Return) usually sends and clears a chat box; judge the last edit seen before it.
            if type == .keyDown && [36, 76].contains(key), self.observation != nil { self.finishObservation(reason: "return_key", submitted: true) }
            // Shortcuts such as ⌘⌫ or ⌘V are edits too; the text diff decides what was learned.
            else if type == .keyDown && key < 123 && ![48, 53].contains(key) { self.observation?.edited = true }
        }
        focusObserver.onChange = { [weak self] kind in self?.focusDidChange(kind) }
        focusObserver.onStatus = { [weak self] status in self?.focusMonitoring = status }
        if monitorSystem { hotkeys.start(); focusObserver.start() }
        capture.onFailure = { [weak self] text in self?.failRecording(text) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        maintenance = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.maintain() } }
    }
    func refresh() throws {
        guard let store else { throw AppError("历史存储尚未就绪。") }
        let loaded = try store.load(Recording.self, kind: "recording").sorted { $0.created > $1.created }
        if records != loaded { records = loaded }
        let terms = try store.load(DictionaryEntry.self, kind: "dictionary").sorted { $0.term < $1.term }
        if dictionary != terms { dictionary = terms }
        preferences = try store.load(Preference.self, kind: "preference")
        corrections = try store.load(Correction.self, kind: "correction").sorted { $0.created < $1.created }
    }
    func perform(_ action: () throws -> Void) { do { try action(); try refresh() } catch { self.error = error.localizedDescription } }
    func saveConfig(_ next: Configuration) {
        perform { guard let store else { throw AppError("存储未就绪。") }; try store.save(next, kind: "configuration", id: "main"); config = next; hotkeys.useFn = next.useFn }
        if !next.learning { observation = nil }
    }
    func toggle() {
        if phase == "recording" { finish(); return }
        if phase == "starting" { cancel(); return }
        guard !busy else { message = "正在处理，可取消后重新录音"; return }
        guard storeReady, config.onboardingDone else { showSettings = true; message = "请先完成首次设置"; return }
        stopObservation("next_dictation"); recoveryText = ""; learnedTerm = nil; learnedCorrectionID = nil; generation = UUID(); let token = generation
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            beginRecording()
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            error = "麦克风权限未开启。请前往系统设置 → 隐私与安全性 → 麦克风。"; return
        }
        phase = "permission"; message = "等待麦克风授权"
        work = Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard token == generation, !Task.isCancelled else { return }
            guard granted else { phase = "idle"; error = "麦克风权限未开启。请前往系统设置 → 隐私与安全性 → 麦克风。"; return }
            beginRecording()
        }
    }
    func beginRecording(captureAudio: ((URL, String) throws -> AudioSink)? = nil, connect: (() async throws -> ModelService)? = nil) {
        guard phase == "idle" || phase == "permission" else { return }
        let token = generation
        message = "正在启动录音…"; phase = "starting"
        // Publish the nonactivating bar before synchronous microphone setup.
        // Cancellation during this yield must prevent both recording and networking.
        work = Task { @MainActor in
            await Task.yield()
            guard valid(token), phase == "starting" else { return }
            do { try startRecording(captureAudio: captureAudio, connect: connect) }
            catch { self.error = safeError(error); if phase == "starting" { phase = "idle" } }
        }
    }
    func startRecording(captureAudio: ((URL, String) throws -> AudioSink)? = nil, connect: (() async throws -> ModelService)? = nil) throws {
        guard let store else { throw AppError("存储未就绪。") }
        guard ["idle", "permission", "starting"].contains(phase) else { throw AppError("当前会话尚未结束。") }
        disconnectRecognition()
        sessionTrace = nil; traceRecordingID = nil
        inputTestID = nil; inputTestEvidence = nil; inputTestResult = ""
        let token = generation, settings = config
        var record = Recording(); record.audioName = "\(record.id).m4a"
        let sink: AudioSink
        do {
            try saveRecording(record); activeID = record.id
            sink = try captureAudio?(store.audioURL(record)!, settings.inputDeviceID)
                ?? capture.start(url: store.audioURL(record)!, deviceID: settings.inputDeviceID, streaming: true)
        } catch {
            let failure = safeError(error)
            failRecording(failure)
            throw AppError(failure)
        }
        // Local audio starts before network I/O; quick finish reuses this same pending session.
        phase = "recording"; elapsed = 0; volume = 0
        cue("Tink")
        message = "正在听写，再按 Fn 结束"
        let owner = UUID(); recordingOwner = owner; recordingSink = sink
        let connection = Task { @MainActor in
            try Task.checkCancellation()
            var service: ModelService
            if let connect { service = try await connect() }
            else if let serviceOverride { service = serviceOverride }
            else {
                service = try ModelService.direct(configuration: settings, session: modelSession)
                // The realtime session starts now, so its reference is the field being dictated into.
                if settings.realtime {
                    let key = contextKey()
                    var context = ""
                    if let inputHooks { context = inputHooks.capture()?.context ?? "" }
                    else if monitorSystem { context = await OptionalContextReader.shared.read().reference?.context ?? "" }
                    if key != contextKey() { context = "" }
                    service.realtimeContext = context; service.realtimeTerms = TermDictionary.recognitionTerms(dictionary, context: context)
                }
            }
            guard !Task.isCancelled, recordingOwner == owner else { throw CancellationError() }
            if settings.realtime { try BailianRealtimeCandidate.requireChannel(service) }
            try service.validate(needsAudio: true, needsRewrite: false)
            return service
        }
        serviceConnection = connection
        work = Task { @MainActor in
            do {
                let service = try await connection.value
                guard valid(token), phase == "recording", activeID == record.id else { return }
                recordingService = service
                if settings.realtime {
                    realtime = try makeRealtime(service: service, sink: sink, owner: owner, recordID: record.id)
                } else if AssemblyStream.matches(service.configuration.sttURL), sink.canStream {
                    let context = InputTarget.capture()?.context ?? ""
                    streaming = try AssemblyStream(configuration: service.configuration, key: service.sttKey, sampleRate: sink.sampleRate, terms: TermDictionary.recognitionTerms(dictionary, context: context), temporaryToken: service.temporaryToken, source: { try sink.drainPCM() })
                    streaming?.onFinal = { [weak self] text in
                        guard let self, self.activeID == record.id else { return }
                        self.saveLiveTranscript(text, id: record.id)
                    }
                } else { sink.disableStreaming() }
            } catch {
                guard valid(token), phase == "recording" else { return }
                message = "正在录音，服务暂不可用；结束后保留音频"
            }
        }
    }
    private func makeRealtime(service: ModelService, sink: AudioSink, owner: UUID, recordID: String) throws -> BailianStream {
        // An existing session fails on its own (and hands over to file recognition) if
        // its buffer overflowed; only a new session needs a streaming sink.
        if let realtime { return realtime }
        guard recordingOwner == owner, sink.canStream else { throw AppError("实时音频会话已失效，音频已保留。") }
        let stream = try BailianStream(service: service, sampleRate: sink.sampleRate, source: { try sink.drainPCM() })
        stream.onFinal = { [weak self, weak stream] text in
            guard let self, let stream, self.realtime === stream, self.recordingOwner == owner, self.activeID == recordID else { return }
            self.saveLiveTranscript(text, id: recordID)
        }
        // A dead session no longer stops the recording (2026-10-10): the local
        // file keeps every word and file recognition takes over at stop.
        stream.onFailure = { [weak sink] in sink?.disableStreaming() }
        realtime = stream; return stream
    }
    // Short cues mark when the microphone is live and when it closed. The start cue
    // plays after capture begins, so it can appear faintly at the start of the audio.
    private func cue(_ name: String) {
        guard monitorSystem, config.interactionSounds ?? true, let sound = NSSound(named: name) else { return }
        sound.volume = 0.35; sound.play()
    }
    func finish(trigger: String = "user_control") {
        guard phase == "recording", let id = activeID, var record = records.first(where: { $0.id == id }) else { return }
        let trace = LatencyRecorder(origin: "stop_requested", stopTrigger: trigger)
        sessionTrace = trace; traceRecordingID = id
        // Close the audio file before any optional accessibility work.
        record.duration = trace.measure("audio_close") { capture.stop() }
        cue("Pop")
        targetHotkeySnapshot = nil
        targetInvalid = false; targetInvalidReason = nil
        target = nil; record.targetApp = ""
        work?.cancel()
        do { try saveRecording(record, stage: "save_audio_closed"); process(record, kind: "initial", source: nil, autoInsert: true) }
        catch { disconnectRecognition(); phase = "idle"; activeID = nil; sessionTrace = nil; traceRecordingID = nil; self.error = error.localizedDescription }
    }
    func testInput(text: String = "Sayvia 输入测试", inspectOnly: Bool = false) {
        guard !busy else { return }
        stopObservation("input_test"); recoveryText = ""; activeID = nil; target = nil; targetInvalid = false; targetInvalidReason = nil; inputTestEvidence = nil; inputTestResult = ""
        let testID = UUID(); inputTestID = testID
        generation = UUID(); let token = generation
        let title = inspectOnly ? "仅检查位置" : "输入测试"
        message = "\(title) · 8 秒后"
        phase = "input_test"; showSettings = false
        work = Task { @MainActor in
            defer {
                if inspectOnly, valid(token), !inputTestResult.isEmpty {
                    // Retain this metadata-only check when a later recording clears
                    // the current test. Its timestamp keeps it distinct from delivery.
                    lastPositionCheck = "上次位置检查 · \(Date().formatted(date: .omitted, time: .standard))\n\(inputTestResult)"
                }
            }
            for remaining in (1...8).reversed() {
                guard valid(token) else { return }
                message = "\(title) · \(remaining) 秒后"
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            guard valid(token) else { return }
            var failure = ""
            phase = "inserting"
            let destination = await captureInsertionTarget()
            guard valid(token) else { return }
            guard let destination else {
                failure = targetInvalidReason ?? "no_input_target"
                inputTestEvidence = InputDeliveryEvidence(capture: InputCaptureEvidence(failure: failure), failureStage: "final_capture", failureReason: failure)
                inputTestResult = "\(inspectOnly ? "位置无法确认" : "测试未写入")：\(failure)"
                message = inspectOnly ? "位置无法确认（未写入）" : "测试未写入，请查看检查结果"
                resultVisibleUntil = Date().addingTimeInterval(8); phase = "idle"; return
            }
            if inspectOnly {
                inputTestEvidence = InputDeliveryEvidence(capture: InputCaptureEvidence(capability: destination.capability, identity: destination.identity), status: "inspect_only")
                inputTestResult = "\(destination.appID)：\(destination.cell != nil ? "单个可写单元格" : destination.readsText ? (destination.readsSelection ? "文字与选区可读" : "正文可回读，选区未验证") : "文字控件，回读未提供") · \(destination.cell != nil ? "整格写入" : "使用文字事件")\(destination.reportsSelectedTextWritable ? " · 提供方报告选中文字可写，仍使用文字事件" : "") · \(destination.captureDetail)"
                message = "位置已确认（未写入）"
                resultVisibleUntil = Date().addingTimeInterval(8); phase = "idle"; return
            }
            let evidence = await destination.deliver(text, isValid: {
                self.valid(token) && !self.targetInvalid && self.currentInputSnapshot() == self.targetHotkeySnapshot
            }, onDiagnostic: { failure = $0 }, capture: inputHooks?.capture, dispatch: inputHooks?.dispatch, setAttribute: inputHooks?.setAttribute, readbackRevision: { self.focusRevision }, onEvidence: { evidence in
                guard self.inputTestID == testID else { return }
                self.inputTestEvidence = evidence
            })
            // Cancellation ends input, but its terminal evidence still belongs
            // to this test. A newer test/recording must never receive it.
            guard inputTestID == testID else { return }
            inputTestEvidence = evidence
            guard valid(token) else {
                inputTestResult = "已取消输入测试：\(insertion(evidence.status))；请核对目标文字。"
                return
            }
            let result = evidence.status
            inputTestResult = "\(destination.appID)：\(insertion(result))（\(result)）\(targetInvalidReason.map { " · " + $0 } ?? "")\(failure.isEmpty ? "" : " · " + failure) · \(focusObserver.diagnostic)"
            message = insertion(result)
            resultVisibleUntil = Date().addingTimeInterval(8); phase = "idle"
        }
    }
    private func currentInputSnapshot() -> HotkeySnapshot? {
        if let inputHooks { return inputHooks.snapshot() }
        return hotkeys.active ? hotkeys.snapshot : nil
    }
    private func captureInputTarget(locked: InputTarget? = nil, onFailure: (String) -> Void = { _ in }, onCandidate: (NSRunningApplication) -> Void = { _ in }) -> InputTarget? {
        if let inputHooks { return inputHooks.capture() }
        if let locked { return monitorSystem ? locked.recapture(onFailure: onFailure) : nil }
        return monitorSystem ? InputTarget.capture(onFailure: onFailure, onCandidate: onCandidate) : nil
    }
    func captureInsertionTarget(capture: (() -> InputTarget?)? = nil, snapshot: (() -> HotkeySnapshot?)? = nil, prepare: (() -> Double?)? = nil) async -> InputTarget? {
        // Earlier navigation is allowed. Only interactions from this final
        // capture onward can invalidate the one permitted input sequence.
        target = nil; targetInvalid = false; targetInvalidReason = nil; targetHotkeySnapshot = nil
        let token = generation
        func currentSnapshot() -> HotkeySnapshot? {
            if let snapshot { return snapshot() }
            return currentInputSnapshot()
        }
        guard let baseline = currentSnapshot() else { invalidateTarget("hotkey_not_active"); return nil }
        targetHotkeySnapshot = baseline
        var deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var failure = "no_input_target"
        var candidate: NSRunningApplication?, preparedApp: NSRunningApplication?
        var preparation = "", extended = false, attempt = 0
        func allowed(_ app: NSRunningApplication) -> Bool {
            // Recheck local guards after the potentially blocking focus IPC.
            !app.isTerminated && NSRunningApplication(processIdentifier: app.processIdentifier) == app &&
            FocusObserver.keyboardPID() == app.processIdentifier && valid(token) && !targetInvalid &&
            target == nil && currentSnapshot() == baseline && AXIsProcessTrusted() && !IsSecureEventInputEnabled()
        }
        func stop(_ reason: String) {
            guard valid(token) else { return }
            let detail = candidate.map { ":candidate_pid_\($0.processIdentifier):candidate_app_\($0.bundleIdentifier ?? "unknown")" } ?? ""
            invalidateTarget(reason + detail + (preparation.isEmpty ? "" : ":accessibility_" + preparation))
        }
        while true {
            guard valid(token) else { return nil }
            guard !targetInvalid, currentSnapshot() == baseline else { invalidateTarget("capture_interaction_race"); return nil }
            if let preparedApp, !allowed(preparedApp) { stop("capture_preparation_guard_changed"); return nil }
            guard attempt == 0 || ProcessInfo.processInfo.systemUptime < deadline else { stop(failure); return nil }
            failure = "no_input_target"
            let captured: InputTarget?
            if let capture { captured = capture() }
            else { captured = captureInputTarget(onFailure: { failure = $0 }, onCandidate: { candidate = $0 }) }
            guard valid(token) else { return nil }
            guard !targetInvalid, currentSnapshot() == baseline else { invalidateTarget("capture_interaction_race"); return nil }
            if let preparedApp, !allowed(preparedApp) { stop("capture_preparation_guard_changed"); return nil }
            if var captured {
                guard ProcessInfo.processInfo.systemUptime < deadline else { stop("capture_deadline:" + failure); return nil }
                if attempt > 0 { captured.captureDetail += ":settled_attempt_\(attempt + 1)" }
                if !preparation.isEmpty { captured.captureDetail += ":accessibility_" + preparation }
                target = captured
                if monitorSystem { focusObserver.refresh(force: true) }
                guard !targetInvalid, currentSnapshot() == baseline else { invalidateTarget("capture_interaction_race"); return nil }
                return captured
            }
            // Only a failed acquisition can settle. A locked target or any
            // dispatched text is never retried or replaced by another field.
            // A slow missing-focus query may exceed the short budget before
            // readiness is requested. Only that request can extend its deadline.
            guard InputTarget.permitsCaptureRetry(failure) else { stop(failure); return nil }
            if let prepare, let until = prepare() { deadline = max(deadline, until); extended = true }
            else if capture == nil, failure.hasPrefix("input_control_unavailable:"), let candidate {
                guard allowed(candidate) else { stop("capture_preparation_guard_changed"); return nil }
                accessibilityRequests = accessibilityRequests.filter { !$0.value.app.isTerminated }
                let pid = candidate.processIdentifier
                if accessibilityRequests[pid] == nil, preparation.isEmpty {
                    let application = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(application, 0.1)
                    preparation = InputTarget.requestAccessibility(application, allowed: { allowed(candidate) }, onAttempt: {
                        self.accessibilityRequests[pid] = (candidate, ProcessInfo.processInfo.systemUptime)
                    })
                }
                guard allowed(candidate) else { stop("capture_preparation_guard_changed"); return nil }
                if let request = accessibilityRequests[pid], request.app == candidate, !request.app.isTerminated {
                    let until = request.time + 2.5
                    if until > ProcessInfo.processInfo.systemUptime {
                        deadline = max(deadline, until); extended = true; preparedApp = candidate
                        if preparation.isEmpty { preparation = "pending_request" }
                    }
                }
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard (extended || attempt < 3), remaining > 0 else {
                stop(failure); return nil
            }
            do { try await Task.sleep(nanoseconds: UInt64(min(extended ? 0.12 : 0.04, remaining) * 1_000_000_000)) } catch { return nil }
            attempt += 1
        }
    }
    func focusDidChange(_ kind: FocusChange) {
        focusRevision &+= 1
        if phase == "inserting", let target {
            var failure = ""
            let current = inputHooks?.capture() ?? (monitorSystem ? target.recapture(readText: false, onFailure: { failure = $0 }) : nil)
            // Selection/value notifications also come from our own input. Recheck
            // identity, never cancel just because one arrived. A momentary read
            // failure while the editor re-renders proves no change; delivery
            // re-proves the target itself right before writing and while reading back.
            if current == nil, InputTarget.transientCaptureFailure(failure) { sessionTrace?.flag("ax_\(kind.rawValue)_transient_read") }
            else if current == nil || !target.matches(current!, content: false) {
                invalidateTarget("ax_\(kind.rawValue)_target_changed:" + (current.flatMap { target.identityDifference(from: $0) } ?? (current == nil ? (failure.isEmpty ? "unavailable" : failure) : "capability")))
            }
        }
        if observation != nil { observeCorrection() }
    }
    private func invalidateTarget(_ reason: String) {
        guard !targetInvalid else { return }
        targetInvalid = true; targetInvalidReason = reason
    }
    func retry(_ record: Recording, kind: String, source: Attempt? = nil) {
        guard !busy, let latest = records.first(where: { $0.id == record.id }), !latest.deleting else { return }
        stopObservation("history_retry"); target = nil
        process(latest, kind: kind, source: source ?? latest.displayed, autoInsert: false)
    }
    func process(_ original: Recording, kind: String, source: Attempt?, autoInsert: Bool) {
        guard let store else { return }
        if !autoInsert { disconnectRecognition() }
        inputTestID = nil; inputTestEvidence = nil; inputTestResult = ""
        recoveryText = ""
        if !autoInsert || traceRecordingID != original.id || sessionTrace == nil {
            sessionTrace = LatencyRecorder(origin: autoInsert ? "pipeline_start" : "history_retry")
            traceRecordingID = original.id
        }
        let trace = sessionTrace!
        var record = original
        let existing = kind == "initial" ? record.attempts.last : nil
        var attempt = existing ?? Attempt(); attempt.kind = kind; attempt.sourceID = source?.id
        attempt.sttModel = config.sttModel; attempt.rewriteModel = config.rewriteModel
        if kind == "rewrite" { attempt.raw = source?.raw ?? "" }
        if existing == nil { record.attempts.append(attempt) }
        do { try saveRecording(record, stage: "save_attempt") } catch { disconnectRecognition(); self.error = error.localizedDescription; phase = "idle"; sessionTrace = nil; traceRecordingID = nil; return }
        generation = UUID(); let token = generation
        activeID = record.id; phase = kind == "rewrite" ? "rewriting" : "recognizing"
        let settings = config
        let liveStream = autoInsert ? streaming : nil
        var liveRealtime = autoInsert ? realtime : nil
        let sourceSink = autoInsert ? recordingSink : nil
        let owner = autoInsert ? recordingOwner : nil
        let startedService = autoInsert ? recordingService : nil
        let pendingService = autoInsert ? serviceConnection : nil
        work = Task { @MainActor in
            guard valid(token) else { liveStream?.cancel(); liveRealtime?.cancel(); return }
            defer { liveStream?.cancel(); liveRealtime?.cancel(); if streaming === liveStream { streaming = nil }; if realtime === liveRealtime { realtime = nil }; if valid(token) { recordingService = nil; serviceConnection = nil; recordingSink = nil; recordingOwner = nil } }
            var stageStarted = ProcessInfo.processInfo.systemUptime
            var recognitionSpan: Int?, rewriteSpan: Int?
            var realtimeFallback = false, fileDiagnostic = ""
            let recognitionPreparation = Task { @MainActor in
                if autoInsert { return await self.prepareContext(stage: "recognition_context", trace: trace) }
                return PreparedContext(key: self.contextKey(), reference: nil)
            }
            var rewritePreparation: Task<PreparedContext, Never>?
            defer { recognitionPreparation.cancel(); rewritePreparation?.cancel() }
            let preparedRules = Result { try trace.measure("rewrite_rules_preparation") { try ModelService.prepareRewriteRules() } }
            do {
                if settings.realtime, autoInsert, kind != "rewrite" {
                    guard sourceSink != nil, owner != nil else { throw AppError(BailianRealtimeCandidate.blockedReason) }
                    if let serviceOverride { try BailianRealtimeCandidate.requireChannel(serviceOverride) }
                }
                let serviceWait = trace.begin("service_ready_wait")
                var serviceReady = false
                defer { trace.end(serviceWait, outcome: serviceReady ? "completed" : "failed") }
                let service: ModelService
                if let serviceOverride { service = serviceOverride }
                else if let startedService { service = startedService }
                else if let pendingService { service = try await pendingService.value }
                else {
                    var sessionSettings = settings
                    if !autoInsert { sessionSettings.realtimeCandidate = false }
                    service = try ModelService.direct(configuration: sessionSettings, session: modelSession)
                }
                guard valid(token) else { return }
                if autoInsert { recordingService = service }
                if settings.realtime, autoInsert, kind != "rewrite" {
                    liveRealtime = try makeRealtime(service: service, sink: sourceSink!, owner: owner!, recordID: record.id)
                }
                serviceReady = true; trace.end(serviceWait)
                attempt.sttModel = service.configuration.sttModel; attempt.rewriteModel = service.configuration.rewriteModel
                try service.validate(needsAudio: kind != "rewrite", needsRewrite: !autoInsert)
                if kind != "rewrite" {
                    guard let audio = store.audioURL(record), FileManager.default.fileExists(atPath: audio.path) else { throw AppError("本地音频不存在，仍可用原始转写重新整理。") }
                    if let latest = records.first(where: { $0.id == record.id }), let saved = latest.attempts.first(where: { $0.id == attempt.id }) { record = latest; attempt.raw = saved.raw }
                    attempt.status = "recognizing"; try persist(record: &record, attempt: attempt, stage: "save_recognition_intent")
                    message = "正在识别…"; stageStarted = ProcessInfo.processInfo.systemUptime
                    let recognitionReference = autoInsert ? await recognitionPreparation.value : nil
                    let recognitionContext = recognitionReference.flatMap { $0.key == contextKey() ? $0.reference?.context : nil } ?? ""
                    guard valid(token) else { return }
                    if autoInsert, settings.overlapContextPreparation != false {
                        rewritePreparation = Task { @MainActor in await self.prepareContext(stage: "rewrite_context_preparation", trace: trace, visibleText: true) }
                    }
                    recognitionSpan = trace.begin("recognition_final")
                    func transcribeFile() async throws -> String {
                        try await service.transcribe(audio: audio, terms: TermDictionary.recognitionTerms(dictionary, context: recognitionContext), context: recognitionContext, onFinal: { [weak self] text in
                            guard let self, self.valid(token) else { return }; self.saveLiveTranscript(text, id: original.id)
                        }, onDiagnostic: { attempt.sttDiagnostic = $0 }, onTrace: { trace.record($0, prefix: "asr") })
                    }
                    if let liveRealtime {
                        // 2026-10-12: file recognition here took p50 6s / p90 30s, slower than
                        // many late realtime finals (the final may take 20s). 6s after the
                        // acknowledged finish, or on a realtime failure, start the one file
                        // recognition and keep realtime running; the first success wins and
                        // the other is cancelled. Nothing is written before this point.
                        enum Leg { case due, realtime(Result<String, Error>), file(Result<String, Error>) }
                        let (legs, emit) = AsyncStream<Leg>.makeStream()
                        liveRealtime.onFallbackDue = { emit.yield(.due) }
                        let realtimeTask = Task { @MainActor in
                            do { emit.yield(.realtime(.success(try await liveRealtime.result(maxWait: 20, fallbackAfter: 6, trace: trace)))) }
                            catch { emit.yield(.realtime(.failure(error))) }
                        }
                        var fileTask: Task<Void, Never>?, pending = 1, winner: String?, failure: Error?
                        func startFile() {
                            guard fileTask == nil else { return }
                            realtimeFallback = true; trace.flag("realtime_file_fallback"); pending += 1
                            fileTask = Task { @MainActor in
                                do { emit.yield(.file(.success(try await transcribeFile()))) }
                                catch { emit.yield(.file(.failure(error))) }
                            }
                        }
                        for await leg in legs {
                            switch leg {
                            case .due: startFile()
                            case .realtime(.success(let text)): attempt.raw = text; winner = "realtime"
                            case .file(.success(let text)): attempt.raw = text; winner = "file"
                            case .realtime(.failure(let error)):
                                pending -= 1; failure = failure ?? error
                                if error is CancellationError || !valid(token) { failure = error; pending = 0 } else { startFile() }
                            case .file(.failure(let error)): pending -= 1; failure = error
                            }
                            if winner != nil || pending == 0 { break }
                        }
                        emit.finish()
                        if winner != "realtime" { realtimeTask.cancel() }
                        fileTask?.cancel(); await fileTask?.value
                        guard valid(token) else { return }
                        guard let winner else { throw Task.isCancelled ? CancellationError() : failure ?? CancellationError() }
                        trace.flag("recognition_winner_" + winner)
                        if winner == "file" {
                            fileDiagnostic = attempt.sttDiagnostic ?? ""
                        } else if realtimeFallback { fileDiagnostic = "lost_to_realtime" }
                    }
                    else if let liveStream { attempt.raw = try await liveStream.result() }
                    else { attempt.raw = try await transcribeFile() }
                    guard valid(token) else { return }
                    attempt.sttMS = Int((ProcessInfo.processInfo.systemUptime - stageStarted) * 1000)
                    if let recognitionSpan { trace.end(recognitionSpan) }
                    if let liveStream { attempt.sttDiagnostic = liveStream.diagnostic }
                    if let liveRealtime { attempt.sttDiagnostic = liveRealtime.diagnostic + (realtimeFallback ? " fallback=file " + fileDiagnostic : "") }
                }
                guard !attempt.raw.isEmpty else { throw AppError("没有可整理的原始文字。") }
                guard valid(token) else { return }
                attempt.status = "rewriting"; try persist(record: &record, attempt: attempt, stage: "save_raw_before_rewrite")
                phase = "rewriting"; message = "正在整理…"; stageStarted = ProcessInfo.processInfo.systemUptime
                var prepared = autoInsert ? await rewritePreparation?.value : nil
                if autoInsert, prepared == nil || prepared?.key != contextKey() {
                    if prepared != nil { trace.flag("rewrite_context_cache_invalidated") }
                    prepared = await prepareContext(stage: "rewrite_context_refresh", trace: trace) // Serial before rewrite: no screen text.
                }
                guard valid(token) else { return }
                let reference = prepared?.key == contextKey() ? prepared?.reference : nil
                let context = reference?.context ?? ""
                let app = autoInsert ? reference?.appID ?? "" : record.targetApp
                let prefs = autoInsert && prepared?.key == contextKey() ? prepared!.preferences : preferences.filter { $0.enabled && ($0.scope.isEmpty || $0.scope == app) }
                let examples = autoInsert && prepared?.key == contextKey() ? prepared!.examples : corrections.filter { $0.enabled && !$0.scope.isEmpty && $0.scope == app }
                let rewriteKey = contextKey()
                rewriteSpan = trace.begin("rewrite")
                do {
                    let rules = try preparedRules.get()
                    if let version = rules["version"] { trace.flag("rewrite_rules_" + version) }
                    attempt.result = try await service.rewrite(raw: attempt.raw, context: context, preferences: prefs, examples: examples, terms: dictionary, onDiagnostic: { attempt.rewriteDiagnostic = $0 }, onModelResult: { attempt.modelResult = $0 }, preparedRules: rules, onTrace: { trace.record($0, prefix: "rewrite") })
                    attempt.status = "succeeded"
                } catch {
                    guard valid(token) else { return }
                    // Keep dictation usable when cleanup fails.
                    guard autoInsert, !(error is CancellationError) else { throw error }
                    attempt.result = attempt.raw; attempt.status = "raw_fallback"; attempt.error = safeError(error)
                    trace.flag("rewrite_raw_fallback")
                }
                guard valid(token) else { return }
                attempt.rewriteMS = Int((ProcessInfo.processInfo.systemUptime - stageStarted) * 1000)
                if let rewriteSpan { trace.end(rewriteSpan, outcome: attempt.status) }
                attempt.finished = Date()
                var completed = record
                completed.successfulID = attempt.id; completed.insertion = "not_attempted"
                try persist(record: &completed, attempt: attempt, stage: "save_result_before_input")
                record = completed
                // Durable result comes before the only allowed external write.
                if autoInsert {
                    phase = "inserting"; message = "正在输入…"
                    record.targetApp = ""
                    let finalCapture = trace.begin("final_target_capture")
                    let destination = await captureInsertionTarget()
                    trace.end(finalCapture, outcome: destination == nil ? "failed" : "completed")
                    guard valid(token) else { return }
                    if let target = destination {
                        record.targetApp = target.appID
                        if target.readsText, target.readsSelection, target.cell == nil {
                            let field = target.value as NSString, end = target.range.location + target.range.length
                            let fitted = end <= field.length ? Safety.fitPunctuation(attempt.result, after: field.substring(from: end)) : attempt.result
                            if fitted != attempt.result { attempt.result = fitted; trace.flag("punctuation_fitted_mid_sentence") }
                        }
                        let contextTargetChanged = rewriteKey != contextKey() || reference.map { $0.identity != target.identity } == true
                        if contextTargetChanged { trace.flag("context_target_changed") }
                        var evidence = InputDeliveryEvidence(capture: InputCaptureEvidence(capability: target.capability, identity: target.identity, interactionGeneration: targetHotkeySnapshot?.generation.uuidString, interactionSerial: targetHotkeySnapshot?.serial))
                        evidence.status = "pending"; evidence.dispatchAttempted = nil; evidence.confirmation = "pending"
                        evidence.route = target.cell == nil ? "pid_unicode" : "ax_cell_value"
                        evidence.plannedSegments = target.cell == nil ? Safety.textChunks(attempt.result).count : 1
                        evidence.checkpoints = ["durable_dispatch_intent"]
                        attempt.delivery = evidence
                        if let index = record.attempts.firstIndex(where: { $0.id == attempt.id }) { record.attempts[index] = attempt }
                        if prepareInsertion(&record) {
                            let insertionStarted = ProcessInfo.processInfo.systemUptime
                            let captureEvidence = evidence.capture
                            evidence = await target.deliver(attempt.result, isValid: { self.valid(token) && !self.targetInvalid && self.currentInputSnapshot() == self.targetHotkeySnapshot }, onDiagnostic: { record.insertionDetail = $0 }, capture: inputHooks?.capture, dispatch: inputHooks?.dispatch, setAttribute: inputHooks?.setAttribute, trace: trace, readbackRevision: { self.focusRevision }, pasteboard: inputHooks == nil && monitorSystem ? NSPasteboard.general : nil, onPasteSession: { session, posted in
                                self.trackPasteRestore(session, posted: posted, text: attempt.result, recordID: record.id, attemptID: attempt.id)
                            }, onEvidence: { evidence in
                                self.updateDeliveryEvidence(evidence, capture: captureEvidence, recordID: record.id, attemptID: attempt.id)
                            })
                            evidence.capture = captureEvidence; attempt.delivery = evidence; record.insertion = evidence.status
                            guard valid(token) else { persistInterruptedDelivery(evidence, trace: trace, recordID: record.id, attemptID: attempt.id); return }
                            attempt.insertionMS = Int((ProcessInfo.processInfo.systemUptime - insertionStarted) * 1000)
                            // Watch any readable field the text reached, not only
                            // fully confirmed ones; the span must still be locatable.
                            // A field that was unreadable at readback may become readable; the
                            // watch still needs the new text located uniquely before it starts.
                            if ["inserted", "input_text_present"].contains(record.insertion) || (record.insertion == "input_dispatched" && target.readsText), !contextTargetChanged, target.cell == nil, config.learning {
                                let current = captureInputTarget(locked: target)
                                let span = current.flatMap { Safety.insertedSpan(attempt.result, in: $0.value, caret: $0.readsSelection ? $0.range : nil) }
                                let skipped = current == nil ? "capture_failed" : !target.matches(current!, content: false) ? "target_changed" : !current!.readsText ? "unreadable" : currentInputSnapshot() != targetHotkeySnapshot ? "interaction" : span == nil ? "span_not_found" : nil
                                if let current, let span, skipped == nil {
                                    var learningTarget = current
                                    learningTarget.placeholder = current.placeholder ?? target.placeholder
                                    observation = (learningTarget, attempt.result, span.prefix, span.suffix, record.id, attempt.id, Date().addingTimeInterval(30), attempt.result, Date(), false)
                                }
                                attempt.delivery?.checkpoints.append(skipped.map { "learning_not_started:" + $0 } ?? "learning_watch_started")
                            }
                        } else { record.insertion = "saved_only"; attempt.delivery?.status = "saved_only"; attempt.delivery?.dispatchAttempted = false; attempt.delivery?.confirmation = "none"; attempt.delivery?.failureStage = "persist_intent"; attempt.delivery?.failureReason = "save_failed" }
                    } else {
                        record.insertion = "saved_only"; attempt.delivery = InputDeliveryEvidence(capture: InputCaptureEvidence(failure: targetInvalidReason), failureStage: "final_capture", failureReason: targetInvalidReason ?? "no_input_target")
                        if inputHooks == nil, monitorSystem, let reason = targetInvalidReason, ClipboardPaste.eligible(reason) {
                            pasteFallback(attempt.result, record: &record, attempt: &attempt, isValid: { self.valid(token) && self.currentInputSnapshot() == self.targetHotkeySnapshot })
                        }
                    }
                }
                if autoInsert { record.insertionDetail = (targetInvalidReason ?? "no_invalidation") + " · " + (record.insertionDetail ?? "") + " · " + hotkeys.diagnostic + " · " + focusObserver.diagnostic }
                attempt.totalMS = Int(trace.snapshot().elapsedMS)
                if let index = record.attempts.firstIndex(where: { $0.id == attempt.id }) { record.attempts[index] = attempt }
                // Sent once to the target counts as success for the user:
                // no prompt. The evidence level stays in history for diagnosis.
                let delivered = ["inserted", "unchanged", "input_text_present", "input_dispatched"].contains(record.insertion)
                recoveryText = autoInsert && !delivered ? attempt.result : ""
                do { try saveRecording(record, stage: "save_final_status"); try saveTraceCheckpoint(record.id) }
                catch { observation = nil; self.error = "文字已保存，但插入状态未能保存；请检查目标，不要重复粘贴。" }
                message = !autoInsert ? "新版本已保存" : delivered ? (attempt.status == "raw_fallback" ? "已输入原文，整理暂不可用" : "已输入") : record.insertion == "input_unconfirmed" ? "未能确认输入，已保存到历史，可复制" : targetInvalid ? ((targetInvalidReason?.hasPrefix("interaction_") == true || targetInvalidReason == "capture_interaction_race") ? "写入前发生操作，文字已保存" : "无法确认输入位置，文字已保存") : target == nil ? "无法确认输入位置，文字已保存" : record.insertion == "unsupported" ? "此输入框不支持直接写入，已保存" : record.insertion == "unchanged" ? "输入位置已有相同文字" : "未自动输入，文字已保存，可复制"
            } catch {
                guard valid(token) else { return }
                let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - stageStarted) * 1000)
                if phase == "recognizing", recognitionSpan != nil { attempt.sttMS = elapsedMS }
                if phase == "rewriting", rewriteSpan != nil { attempt.rewriteMS = elapsedMS }
                if let recognitionSpan { trace.end(recognitionSpan, outcome: "failed") }
                if let rewriteSpan { trace.end(rewriteSpan, outcome: "failed") }
                attempt.totalMS = Int(trace.snapshot().elapsedMS)
                if let liveStream { attempt.sttDiagnostic = liveStream.diagnostic }
                if let liveRealtime { attempt.sttDiagnostic = liveRealtime.diagnostic + (realtimeFallback ? " fallback=file " + fileDiagnostic : "") }
                if let saved = records.first(where: { $0.id == record.id })?.attempts.first(where: { $0.id == attempt.id }), !saved.raw.isEmpty { attempt.raw = saved.raw }
                if let liveStream, !liveStream.partialText.isEmpty { attempt.raw = liveStream.partialText }
                attempt.status = "failed"; attempt.error = safeError(error); attempt.finished = Date()
                do { try persist(record: &record, attempt: attempt, stage: "save_failure"); try saveTraceCheckpoint(record.id) } catch { self.error = "无法保存处理结果，音频保留在应用目录。" }
                recoveryText = attempt.raw
                message = phase == "rewriting" ? "整理失败，原文可复制" : (error as? AppError)?.isNoSpeech == true && attempt.raw.isEmpty ? "没有识别到语音" : "识别未完成，已完成转写可复制"
                self.error = attempt.error
            }
            if valid(token) { phase = "idle"; resultVisibleUntil = !recoveryText.isEmpty ? .distantFuture : message == "已输入" ? .distantPast : Date().addingTimeInterval(3); activeID = nil; target = nil; sessionTrace = nil; traceRecordingID = nil }
        }
    }
    func saveLiveTranscript(_ text: String, id: String) {
        guard !text.isEmpty, var record = records.first(where: { $0.id == id }) else { return }
        if record.attempts.isEmpty {
            var attempt = Attempt(); attempt.status = "recognizing"; attempt.sttModel = config.sttModel; attempt.rewriteModel = config.rewriteModel
            record.attempts.append(attempt)
        }
        guard ["pending", "recognizing"].contains(record.attempts.last?.status ?? "") else { return }
        record.attempts[record.attempts.count - 1].raw = text
        // Retain received text for cancellation/failure recovery even if this
        // first save fails. Status remains recognizing; memory is not durability.
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
        do { try saveRecording(record) } catch { self.error = "转写暂未保存，原始音频仍在本机。" }
    }
    private func valid(_ token: UUID) -> Bool { token == generation && !Task.isCancelled }
    private func safeError(_ error: Error) -> String {
        if let app = error as? AppError { return app.message }
        if error is DecodingError { return "模型响应格式不兼容，已有内容已保留。" }
        if let urlError = error as? URLError {
            let reason: String
            switch urlError.code {
            case .timedOut: reason = "模型请求超时"
            case .networkConnectionLost: reason = "服务连接在响应前中断"
            case .notConnectedToInternet: reason = "设备未连接网络"
            case .cannotFindHost, .dnsLookupFailed: reason = "无法解析模型服务地址"
            case .cannotConnectToHost: reason = "无法连接模型服务"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot: reason = "模型服务 TLS 连接失败"
            case .cancelled: reason = "模型请求被取消"
            default: reason = "模型网络请求失败"
            }
            return "\(reason)（网络代码 \(urlError.errorCode)），原文和音频已保留。"
        }
        return "处理未完成，请检查文件、服务配置与网络。"
    }
    private func saveRecording(_ original: Recording, stage: String = "save_recording", traceOverride: LatencyRecorder? = nil) throws {
        guard let store else { throw AppError("历史存储尚未就绪。") }
        var record = original
        let trace = traceOverride ?? (traceRecordingID == record.id ? sessionTrace : nil)
        let span = trace?.begin(stage)
        if let trace, !record.attempts.isEmpty { record.attempts[record.attempts.count - 1].trace = trace.snapshot() }
        do { try inputHooks?.beforeSave?(stage); try store.save(record, kind: "recording", id: record.id) }
        catch { if let span { trace?.end(span, outcome: "failed") }; throw error }
        if let span { trace?.end(span) }
        // A failed full-list read must never leave cancellation holding an older version.
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.insert(record, at: 0) }
    }
    // AX could not prove a text control. Paste once via a temporary clipboard
    // and restore it; never retried, never learned, status stays dispatch-only.
    private func pasteFallback(_ text: String, record: inout Recording, attempt: inout Attempt, isValid: () -> Bool) {
        func skip(_ reason: String) { attempt.delivery?.failureStage = "paste_fallback"; attempt.delivery?.failureReason = reason }
        let board = NSPasteboard.general
        guard isValid(), AXIsProcessTrusted(), !IsSecureEventInputEnabled(), CGPreflightPostEventAccess() else { return skip("paste_guard_failed") }
        guard let pid = FocusObserver.keyboardPID(), pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return skip("paste_no_keyboard_app") }
        // A previous paste still waiting would be snapshotted as the original.
        guard ClipboardPaste.pending == nil else { return skip("paste_previous_restore_pending") }
        var evidence = attempt.delivery ?? InputDeliveryEvidence()
        evidence.route = "paste_restore"; evidence.status = "pending"; evidence.dispatchAttempted = nil; evidence.confirmation = "pending"
        evidence.plannedSegments = 1; evidence.checkpoints = ["durable_dispatch_intent"]
        let previous = attempt.delivery
        attempt.delivery = evidence; record.targetApp = app.bundleIdentifier ?? ""
        if let index = record.attempts.firstIndex(where: { $0.id == attempt.id }) { record.attempts[index] = attempt }
        guard prepareInsertion(&record) else { attempt.delivery = previous; record.insertion = "saved_only"; return skip("save_failed") }
        func finish(_ status: String, dispatched: Bool, _ reason: String? = nil) {
            evidence.status = status; evidence.dispatchAttempted = dispatched; evidence.confirmation = dispatched ? "dispatch_only" : "none"
            if let reason { evidence.failureStage = "paste_fallback"; evidence.failureReason = reason }
            attempt.delivery = evidence; record.insertion = status
        }
        // Snapshot right before writing; begin() refuses if the user copied in between.
        // Unreadable items (e.g. file promises) cannot be restored, so no paste.
        guard let saved = ClipboardPaste.snapshot(board) else { return finish("saved_only", dispatched: false, "paste_clipboard_snapshot_unavailable") }
        guard !ClipboardPaste.concealed(saved) else { return finish("saved_only", dispatched: false, "paste_clipboard_concealed") }
        guard let session = ClipboardPaste.begin(text, saved: saved, to: board) else { return finish("saved_only", dispatched: false, "paste_clipboard_write_failed") }
        guard isValid(), FocusObserver.keyboardPID() == pid, !IsSecureEventInputEnabled() else {
            ClipboardPaste.restore(session, to: board); return finish("saved_only", dispatched: false, "paste_target_changed")
        }
        evidence.checkpoints.append("dispatch_started")
        let posted = ClipboardPaste.commandV(pid: pid)
        if posted { evidence.dispatchedSegments = 1; evidence.checkpoints.append("dispatch_complete") }
        posted ? finish("input_dispatched", dispatched: true) : finish("saved_only", dispatched: false, "paste_event_creation_failed")
        trackPasteRestore(session, posted: posted, text: text, recordID: record.id, attemptID: attempt.id)
    }
    // Restores the user's clipboard after a paste, then records the outcome once
    // the pipeline has saved its own final status.
    private func trackPasteRestore(_ session: ClipboardPaste.Session, posted: Bool, text: String, recordID: String, attemptID: String) {
        let board = NSPasteboard.general, generation = generation
        // Unstructured so cancelling this pipeline can never skip the restore.
        Task { @MainActor in
            let outcome = await ClipboardPaste.finish(session, to: board, posted: posted)
            if outcome == "failed" { self.error = "原剪贴板未能恢复，请重新复制需要的内容。" }
            // Let the pipeline save its final status first (bounded at 30 s).
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while self.activeID == recordID, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard var latest = self.records.first(where: { $0.id == recordID }), latest.attempts.last?.id == attemptID else { return }
            let unread = posted && session.provider.reads == 0
            latest.attempts[latest.attempts.count - 1].delivery?.checkpoints.append("clipboard_" + outcome + (unread ? "_target_never_read" : ""))
            // Nobody took the text (e.g. no input box at all) and readback did not see it: not written.
            if unread, latest.insertion == "input_dispatched" {
                latest.insertion = "input_unconfirmed"
                latest.attempts[latest.attempts.count - 1].delivery?.status = "input_unconfirmed"
                if self.generation == generation, !self.busy {
                    self.recoveryText = text; self.message = "未写入，已保存到历史，可复制"; self.resultVisibleUntil = .distantFuture
                }
            }
            try? self.saveRecording(latest, stage: "save_clipboard_restore")
        }
    }
    func prepareInsertion(_ record: inout Recording) -> Bool {
        var pending = record; pending.insertion = "unknown"
        do { try saveRecording(pending, stage: "save_dispatch_intent"); record = pending; return true }
        catch {
            self.error = "文字已保存，但写入状态保存失败，已停止自动插入；可从历史复制。"
            return false
        }
    }
    private func persist(record: inout Recording, attempt: Attempt, stage: String = "save_attempt_version") throws {
        guard let index = record.attempts.firstIndex(where: { $0.id == attempt.id }) else { throw AppError("处理版本不存在。") }
        record.attempts[index] = attempt
        try saveRecording(record, stage: stage)
    }
    private func saveTraceCheckpoint(_ id: String, traceOverride: LatencyRecorder? = nil) throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        // The checkpoint carries timings of all substantive saves. Its own
        // end remains unknown on disk; recursively saving that end never terminates.
        try saveRecording(record, stage: "save_trace_checkpoint", traceOverride: traceOverride)
    }
    private func updateDeliveryEvidence(_ delivery: InputDeliveryEvidence, capture: InputCaptureEvidence, recordID: String, attemptID: String) {
        guard let r = records.firstIndex(where: { $0.id == recordID }), records[r].attempts.last?.id == attemptID else { return }
        var delivery = delivery; delivery.capture = capture
        records[r].attempts[records[r].attempts.count - 1].delivery = delivery
    }
    private func persistInterruptedDelivery(_ delivery: InputDeliveryEvidence, trace: LatencyRecorder, recordID: String, attemptID: String) {
        guard var latest = records.first(where: { $0.id == recordID }), latest.attempts.last?.id == attemptID else { return }
        trace.flag("input_cancelled")
        latest.insertion = delivery.dispatchAttempted == true ? "input_unconfirmed" : "saved_only"
        latest.attempts[latest.attempts.count - 1].delivery = delivery
        latest.attempts[latest.attempts.count - 1].trace = trace.snapshot()
        do { try saveRecording(latest, stage: "save_interrupted_input", traceOverride: trace); try saveTraceCheckpoint(recordID, traceOverride: trace) }
        catch { self.error = "已取消；送达状态未能保存，请核对输入框，不要重复输入。" }
    }
    private func disconnectRecognition() {
        streaming?.cancel(); streaming = nil
        recordingService = nil
        realtime?.cancel(); realtime = nil; recordingSink = nil; recordingOwner = nil
        serviceConnection?.cancel(); serviceConnection = nil
    }
    func cancel() { if busy { cue("Bottle") }; stopSession() }
    private func failRecording(_ failure: String) { stopSession(recordingFailure: failure) }
    private func stopSession(recordingFailure: String? = nil) {
        let wasInserting = phase == "inserting"
        if let recordingFailure { self.error = recordingFailure }
        disconnectRecognition()
        generation = UUID(); work?.cancel(); work = nil; stopObservation("session_stopped"); target = nil
        let time = capture.stop()
        if let id = activeID, var record = records.first(where: { $0.id == id }) {
            if phase == "recording" { record.duration = time }
            if record.attempts.isEmpty { record.attempts.append(Attempt()) }
            let index = record.attempts.count-1
            sessionTrace?.flag(recordingFailure == nil ? "cancelled" : "recording_failed")
            if wasInserting { record.insertion = record.attempts[index].delivery?.dispatchAttempted == true ? "input_unconfirmed" : "saved_only" }
            if !["succeeded", "raw_fallback"].contains(record.attempts[index].status) {
                record.attempts[index].status = recordingFailure == nil ? "cancelled" : "failed"
                if let recordingFailure { record.attempts[index].error = recordingFailure }
                record.attempts[index].finished = Date()
            }
            perform { try saveRecording(record, stage: "save_cancelled"); try saveTraceCheckpoint(record.id) }
        }
        activeID = nil; phase = "idle"
        sessionTrace = nil; traceRecordingID = nil
        message = recordingFailure ?? (wasInserting ? "已取消，请检查输入框；部分文字可能已输入" : "已取消，已有录音与文字已保留")
        resultVisibleUntil = Date().addingTimeInterval(recordingFailure == nil ? 3 : 8)
    }
    private func tick() {
        if monitorSystem { hotkeys.start(); focusObserver.start() }
        if phase == "recording" {
            elapsed = capture.duration; volume = capture.level
            let limit = recordingService?.maximumRecordingSeconds ?? 300
            if limit > 0, elapsed >= Double(limit - 3) { finish(trigger: "duration_limit") }
            let remaining = limit > 0 ? max(0, limit - 3 - Int(elapsed)) : Int.max
            let shown = remaining <= 30 ? remaining : nil
            if recordingRemaining != shown { recordingRemaining = shown }
        } else if recordingRemaining != nil { recordingRemaining = nil }
        if ["starting", "recognizing", "rewriting", "inserting"].contains(phase) {
            let seconds = Int(ProcessInfo.processInfo.systemUptime - phaseStarted)
            if processingSeconds != seconds { processingSeconds = seconds }
        }
        observeCorrection()
    }
    private func observeCorrection() {
        guard var watch = observation else { return }
        guard config.learning else { return stopObservation("disabled") }
        guard Date() < watch.deadline else { return finishObservation(reason: "deadline", submitted: true) }
        if let pid = FocusObserver.keyboardPID(), pid != watch.target.pid { return finishObservation(reason: "left_app", submitted: true) }
        // Rich editors drop their text or selection proof for a moment while they
        // update. Skip such a tick; only a different field ends the watch.
        guard var current = captureInputTarget(locked: watch.target) else { return }
        if let change = watch.target.identityDifference(from: current) {
            // Chromium editors briefly report another element for the same field, so
            // within one window wait until the last edit settled; a new window or app is final.
            if change == "element_changed" { if Date().timeIntervalSince(watch.changedAt) >= learningSettle { finishObservation(reason: "left_field") }; return }
            return finishObservation(reason: "left_" + change, submitted: true)
        }
        // A fallback representation is not a user edit, even in the same field.
        guard watch.target.matches(current, content: false), current.textSource == watch.target.textSource else { return }
        current.placeholder = current.placeholder ?? watch.target.placeholder
        // A box emptied in one step (possibly back to its hint) was usually sent with a
        // Send button: judge the last edit seen, as with Return. Gradual deletion
        // never jumps straight to empty, and the hint itself is never learned.
        if current.value.isEmpty || current.isPlaceholderSnapshot {
            return watch.last.count > 3 ? finishObservation(reason: "field_cleared", submitted: true) : stopObservation("cleared")
        }
        guard current.value.utf16.starts(with: watch.prefix.utf16),
              current.value.utf16.suffix(watch.suffix.utf16.count).elementsEqual(watch.suffix.utf16),
              current.value.utf16.count >= watch.prefix.utf16.count + watch.suffix.utf16.count else { return stopObservation("edit_outside_dictation") }
        let changed = (current.value as NSString).substring(with: NSRange(location: watch.prefix.utf16.count, length: current.value.utf16.count - watch.prefix.utf16.count - watch.suffix.utf16.count))
        // An ongoing edit keeps the watch alive (15 s past the last change).
        if changed != watch.last { watch.last = changed; watch.changedAt = Date(); watch.deadline = max(watch.deadline, Date().addingTimeInterval(15)); observation = watch }
        else if watch.edited, changed != watch.text, Date().timeIntervalSince(watch.changedAt) >= learningSettle { finishObservation(reason: "settled") }
    }
    // Every end of a learning watch leaves one reason on its attempt, so a missed
    // correction can be diagnosed from history (reason names only, never text).
    private func stopObservation(_ reason: String) {
        guard let watch = observation else { return }; observation = nil
        noteLearning(watch.recordID, watch.attemptID, "stopped:" + reason)
    }
    private func finishObservation(reason: String, submitted: Bool = false) {
        guard let watch = observation else { return }; observation = nil
        let outcome = !config.learning ? "disabled" : !watch.edited ? "no_typing" : !(submitted || Date().timeIntervalSince(watch.changedAt) >= learningSettle) ? "still_editing" : watch.last == watch.text ? "unchanged" : !Safety.correction(before: watch.text, after: watch.last) && CorrectionReview.candidates(before: watch.text, after: watch.last).isEmpty ? "edit_too_large" : nil
        noteLearning(watch.recordID, watch.attemptID, "finished:\(reason):" + (outcome ?? "correction"))
        guard outcome == nil else { return }
        let example = Correction(recordingID: watch.recordID, attemptID: watch.attemptID, before: watch.text, after: watch.last, scope: watch.target.appID)
        learn(example)
    }
    private func noteLearning(_ recordID: String, _ attemptID: String, _ event: String) {
        guard var record = records.first(where: { $0.id == recordID }), let index = record.attempts.firstIndex(where: { $0.id == attemptID }), record.attempts[index].delivery != nil else { return }
        record.attempts[index].delivery?.checkpoints.append("learning_" + event)
        try? saveRecording(record, stage: "save_learning_note")
    }
    func learn(_ original: Correction) {
        guard config.learning, let store, records.contains(where: { $0.id == original.recordingID && $0.attempts.contains(where: { $0.id == original.attemptID }) }) else { return }
        let candidates = CorrectionReview.candidates(before: original.before, after: original.after)
        var example = original
        // A long addition or several scattered fixes is kept as evidence only
        // around the reviewed spans: short local pairs, never the long text.
        if !Safety.correction(before: example.before, after: example.after) {
            guard !candidates.isEmpty else { return }
            example.before = candidates.map(\.original).joined(separator: " … ")
            example.after = candidates.map(\.corrected).joined(separator: " … ")
        }
        var saved = false
        perform {
            try store.transaction {
                try store.save(example, kind: "correction", id: example.id)
                noteLearning(example.recordingID, example.attemptID, candidates.isEmpty ? "example_only" : "review_started")
                let evidence = (corrections + [example]).filter { $0.enabled && $0.scope == example.scope && $0.before == example.before && $0.after == example.after }
                if !example.scope.isEmpty, Set(evidence.map(\.recordingID)).count >= 2 {
                    let instruction = "在相同表达情境中，参考将「\(example.before)」改为「\(example.after)」的习惯，不能改变原意。"
                    var preference = preferences.first { $0.origin == "automatic" && $0.instruction == instruction && $0.scope == example.scope } ?? Preference(instruction: instruction, scope: example.scope, origin: "automatic")
                    preference.evidenceIDs = evidence.map(\.id)
                    try store.save(preference, kind: "preference", id: preference.id)
                }
            }
            saved = true
        }
        guard saved, !candidates.isEmpty else { return }
        let service: ModelService
        do {
            if let serviceOverride { service = serviceOverride }
            else { service = try ModelService.direct(configuration: config, session: modelSession) }
        } catch { return noteLearning(example.recordingID, example.attemptID, "review_failed") }
        learningReview = Task { [weak self] in
            let decisions = try? await service.reviewCorrections(candidates)
            self?.applyReview(example, decisions)
        }
    }
    private func applyReview(_ example: Correction, _ decisions: [CorrectionReview.Decision]?) {
        guard let decisions else { return noteLearning(example.recordingID, example.attemptID, "review_failed") }
        var added: [String] = [], created: [String] = [], restore: [DictionaryEntry] = [], committed = false
        perform {
            guard let store else { return }
            // Undo, reset, deletion or switching learning off while the review ran wins.
            guard config.learning, try store.load(Correction.self, kind: "correction").contains(where: { $0.id == example.id && $0.enabled }) else { return }
            let blocked = try store.blockedTerms()
            try store.transaction {
                var entries = try store.load(DictionaryEntry.self, kind: "dictionary")
                for decision in decisions where !blocked.contains(TermDictionary.key(decision.term)) {
                    if let index = entries.firstIndex(where: { TermDictionary.key($0.term) == TermDictionary.key(decision.term) }) {
                        // Another mishearing of a learned word joins it; manual and
                        // built-in words stay exactly as the user set them.
                        let existing = entries[index]
                        guard existing.origin == "automatic" else { continue }
                        var merged = existing; merged.aliases += decision.aliases
                        guard let valid = try? TermDictionary.validated(merged, others: entries), valid.aliases != existing.aliases else { continue }
                        try store.save(valid, kind: "dictionary", id: valid.id)
                        entries[index] = valid; restore.append(existing)
                    } else {
                        let entry = DictionaryEntry(term: decision.term, origin: "automatic", sourceID: example.id, aliases: decision.aliases)
                        // A conflicting alias must not discard the correction evidence.
                        guard let valid = try? TermDictionary.validated(entry, others: entries) else { continue }
                        try store.save(valid, kind: "dictionary", id: valid.id)
                        entries.append(valid); created.append(valid.term)
                    }
                    added.append(decision.term)
                }
                noteLearning(example.recordingID, example.attemptID, added.isEmpty ? "review_rejected" : "term_added")
            }
            committed = true
        }
        guard committed, !added.isEmpty, !busy else { return }
        learnedTerm = added.joined(separator: "」「"); learnedCorrectionID = example.id; learnedRestore = restore; learnedCreated = created; recoveryText = ""
        message = created.isEmpty ? "已为「\(learnedTerm!)」补充误识别写法" : "已将「\(learnedTerm!)」加入词典"
        resultVisibleUntil = Date().addingTimeInterval(6)
    }
    func stopLearningObservation() { observation = nil }
    // Removes the correction evidence and the dictionary entry it created.
    func undoLearnedTerm() {
        guard let id = learnedCorrectionID else { return }
        perform { try store?.undoLearning(id, restoring: learnedRestore, blocking: learnedCreated) }
        learnedTerm = nil; learnedCorrectionID = nil; learnedRestore = []; learnedCreated = []
        message = "已撤销"; resultVisibleUntil = Date().addingTimeInterval(2)
    }
    func edit(_ recording: Recording, text: String) {
        guard !busy, var record = records.first(where: { $0.id == recording.id }), !record.deleting, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var attempt = Attempt()
        let previousText = record.text
        attempt.kind = "edit"; attempt.sourceID = record.displayed?.id; attempt.raw = record.displayed?.raw ?? ""
        attempt.result = text; attempt.status = "succeeded"; attempt.finished = Date()
        record.attempts.append(attempt); record.successfulID = attempt.id; record.insertion = "not_attempted"
        do { try saveRecording(record); try refresh() } catch { self.error = error.localizedDescription; return }
        if config.learning, Safety.correction(before: previousText, after: text) || !CorrectionReview.candidates(before: previousText, after: text).isEmpty {
            learn(Correction(recordingID: record.id, attemptID: attempt.id, before: previousText, after: text, scope: record.targetApp))
        }
    }
    func maintain() {
        guard !busy, let store else { return }
        for record in records where record.deleting || Safety.expired(record, days: config.retentionDays) {
            if observation?.recordID == record.id { observation = nil }
            do { try store.deleteRecording(record) } catch { self.error = "部分历史待清理，音频尚未确认删除。" }
        }
        do { try refresh() } catch { self.error = error.localizedDescription }
    }
    func delete(_ record: Recording) { guard !busy else { return }; observation = nil; perform { try store?.deleteRecording(record) } }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func play(_ record: Recording) {
        perform { guard let url = store?.audioURL(record) else { throw AppError("音频不存在。") }; player?.stop(); player = try AVAudioPlayer(contentsOf: url); player?.play() }
    }
    func export(_ record: Recording) {
        guard let url = store?.audioURL(record) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Sayvia-\(record.id.prefix(8)).m4a"
        if panel.runModal() == .OK, let destination = panel.url { perform { if destination.standardizedFileURL == url.standardizedFileURL { return }; let data = try Data(contentsOf: url); try data.write(to: destination, options: .atomic) } }
    }
    func feedback() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Sayvia-diagnostics.txt"
        if panel.runModal() == .OK, let url = panel.url {
            perform { try "Sayvia 0.1\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nHistory count: \(records.count)\nStates: \(Dictionary(grouping: records, by: \.latestStatus).mapValues(\.count))\n不包含音频、原文、上下文或 API Key。\n".write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
