import AppKit
import AVFoundation
import ApplicationServices
import Carbon
import CoreAudio
import AudioToolbox

// Audio callbacks run off the main thread; the sink serializes file writes and meter reads.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var peak = 0.0
    private var failed = false
    private let streamQueue: StreamingPCMQueue
    private var streaming = false
    private var streamOverflow = false
    let sampleRate: Double
    init(url: URL, format: AVAudioFormat) throws {
        sampleRate = format.sampleRate
        streamQueue = StreamingPCMQueue(sampleRate: format.sampleRate)
        // Let AAC choose a supported bitrate: low-rate mono inputs can reject 96 kbps.
        do {
            file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            throw AppError("录音文件初始化失败，请检查输入设备和本机存储（音频错误 \((error as NSError).code)）。")
        }
    }
    func enableStreaming() { lock.lock(); defer { lock.unlock() }; streaming = true }
    func disableStreaming() { lock.lock(); defer { lock.unlock() }; streaming = false; streamQueue.cancel() }
    var canStream: Bool { lock.lock(); defer { lock.unlock() }; return !streamOverflow }
    func drainPCM() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !streamOverflow else { throw AppError("流式音频转换或发送失败，原始音频已保留，不会自动重传。") }
        return try streamQueue.drainPCM()
    }
    static func monoPCM(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved else { throw AppError("音频格式不支持流式识别。") }
        var samples = [Int16](repeating: 0, count: Int(buffer.frameLength))
        for frame in samples.indices {
            var value: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) { value += channels[channel][frame] }
            value /= Float(buffer.format.channelCount)
            samples[frame] = Int16(max(-32768, min(32767, (value.isFinite ? value : 0) * 32767))).littleEndian
        }
        return samples.withUnsafeBytes { Data($0) }
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, !failed else { return }
        do { try file.write(from: buffer); frames += AVAudioFramePosition(buffer.frameLength) } catch { failed = true }
        if streaming, !streamOverflow {
            // Bound startup buffering across session acquisition and WebSocket connection (15 s each).
            do { try streamQueue.appendPCM(Self.monoPCM(buffer)) }
            catch { streamOverflow = true }
        }
        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            var rms = 0.0
            for channel in 0..<Int(buffer.format.channelCount) {
                var sum = 0.0
                for index in 0..<Int(buffer.frameLength) { let sample = Double(channels[channel][index]); if sample.isFinite { sum += sample * sample } }
                rms = max(rms, sqrt(sum / Double(buffer.frameLength)))
            }
            peak = max(Self.meter(rms: rms), peak * 0.75)
        }
    }
    static func meter(rms: Double) -> Double { min(1, max(0, (20 * log10(max(rms.isFinite ? rms : 0, 0.000001)) + 60) / 48)) }
    func state() -> (Double, Double, Bool) { lock.lock(); defer { lock.unlock() }; return (Double(frames) / sampleRate, peak, failed) }
    func close() { lock.lock(); defer { lock.unlock() }; file = nil; streamQueue.finish() }
}

@MainActor
final class AudioCapture {
    private var engine: AVAudioEngine?
    private var sink: AudioSink?
    var onFailure: ((String) -> Void)?
    var duration: Double { sink?.state().0 ?? 0 }
    var level: Double {
        guard let state = sink?.state() else { return 0 }
        if state.2 { onFailure?("录音写入失败，已有音频已保留。") }
        return state.1
    }
    static var devices: [AVCaptureDevice] { AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices }
    func start(url: URL, deviceID: String, streaming: Bool = false, syntheticFormat: AVAudioFormat? = nil) throws -> AudioSink {
        // Self-check replaces only the microphone boundary; file ownership and
        // the production stop/close path remain under AudioCapture.
        if let syntheticFormat {
            let sink = try AudioSink(url: url, format: syntheticFormat)
            if streaming { sink.enableStreaming() }
            self.sink = sink; return sink
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceID.isEmpty {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uid: CFString = deviceID as CFString
            var device = AudioDeviceID(0)
            let result = withUnsafeMutablePointer(to: &uid) { uidPointer in
                withUnsafeMutablePointer(to: &device) { devicePointer in
                    var translation = AudioValueTranslation(mInputData: uidPointer, mInputDataSize: UInt32(MemoryLayout<CFString>.size), mOutputData: devicePointer, mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size))
                    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation)
                }
            }
            guard result == noErr, device != 0, let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw AppError("所选麦克风不可用，请重新选择输入设备。") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError("没有可用的麦克风。") }
        let sink = try AudioSink(url: url, format: format)
        if streaming { sink.enableStreaming() }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in sink.append(buffer) }
        do { try engine.start() } catch { input.removeTap(onBus: 0); sink.close(); throw AppError("麦克风启动失败，请检查权限和设备。") }
        self.engine = engine; self.sink = sink
        return sink
    }
    func stop() -> Double {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        let time = duration; sink?.close(); sink = nil; engine = nil
        return time
    }
}

@MainActor
struct InputTarget {
    let element: AXUIElement
    let pid: pid_t
    let appID: String
    let value: String
    let range: NSRange
    let window: AXUIElement
    var readsText = true
    var readsSelection = true
    var textSource = "value"
    var textMetadata = ""
    var placeholder: String? = nil
    var captureDetail = ""
    var cell: SelectedCell? = nil
    // A provider's writable claim does not prove its setter changes the editor.
    var reportsSelectedTextWritable = false

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func parameterizedAttribute(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }
    static func processIdentifier(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }
    static func focusedTextDescendant(_ root: AXUIElement, read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute, isSettable: @MainActor (AXUIElement, String) -> Bool = attributeIsSettable, parameterized: @MainActor (AXUIElement, String, CFTypeRef) -> CFTypeRef? = parameterizedAttribute, pidOf: @MainActor (AXUIElement) -> pid_t? = processIdentifier, onScope: (AXUIElement) -> Void = { _ in }, onFailure: (String) -> Void = { _ in }, onMarkerDiagnostic: (String) -> Void = { _ in }) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        var branch = root, chain = [root], restrictedScope: AXUIElement?
        var expired = false
        func inTime() -> Bool {
            guard !expired, ProcessInfo.processInfo.systemUptime < deadline else {
                if !expired { onFailure("focus_search_deadline") }
                expired = true; return false
            }
            return true
        }
        func query(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard inTime() else { return nil }
            let result = read(node, name)
            return inTime() ? result : nil
        }
        func markerEditor() -> AXUIElement? {
            let found = focusedMarkerEditor(branch, read: query, parameterized: { node, name, parameter in
                guard inTime() else { return nil }
                let result = parameterized(node, name, parameter)
                return inTime() ? result : nil
            }, pidOf: pidOf, onFailure: onFailure, onDiagnostic: onMarkerDiagnostic)
            guard inTime(), let found else { return nil }
            if let restrictedScope {
                let contained = isDescendant(found, of: restrictedScope, read: query)
                guard inTime() else { return nil }
                guard contained else { onFailure("nested_focus_outside_wrapper"); return nil }
            }
            onMarkerDiagnostic("marker_focus_resolved")
            return found
        }
        guard query(root, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { onFailure("secure_text_field"); return nil }
        // Focus references can pass through several wrappers not listed as children.
        // Once a reference narrows the branch, never search the original siblings.
        for depth in 0..<12 {
            guard inTime() else { return nil }
            guard let reference = query(branch, kAXFocusedUIElementAttribute) else { break }
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { onFailure("invalid_nested_focus"); return nil }
            let leaf = reference as! AXUIElement
            if CFEqual(leaf, branch) { break }
            guard !chain.contains(where: { CFEqual($0, leaf) }) else { onFailure("focus_reference_cycle"); return nil }
            let branchRole = query(branch, kAXRoleAttribute) as? String ?? ""
            guard inTime() else { return nil }
            // WebKit's focus getter can be document-wide. A non-text wrapper
            // must actually contain its referenced editor, never a sibling field.
            if !["AXWebArea", kAXGroupRole, kAXUnknownRole, kAXApplicationRole, kAXWindowRole, kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(branchRole) { restrictedScope = branch }
            if let restrictedScope {
                let contained = isDescendant(leaf, of: restrictedScope, read: query)
                guard inTime() else { return nil }
                guard contained else { onFailure("nested_focus_outside_wrapper"); return nil }
            }
            AXUIElementSetMessagingTimeout(leaf, 0.025)
            guard query(leaf, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { onFailure("secure_text_field"); return nil }
            let role = query(leaf, kAXRoleAttribute) as? String ?? "unknown"
            guard inTime() else { return nil }
            if ([kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, kAXStaticTextRole] + SelectedCell.roles).contains(role) ||
               hasCustomEditingCapability(leaf, read: query, isSettable: isSettable) { return leaf }
            branch = leaf; chain.append(leaf)
            if depth == 11 { onFailure("focus_reference_limit"); return nil }
        }
        let role = query(branch, kAXRoleAttribute) as? String ?? ""
        guard inTime() else { return nil }
        guard ["AXWebArea", kAXGroupRole, kAXUnknownRole, kAXApplicationRole, kAXWindowRole, kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else {
            if let editor = markerEditor() { return editor }
            if inTime(), !CFEqual(branch, root) { onFailure("non_text_focused_child:\(role)") }
            return nil
        }
        onScope(branch)
        var pending = (query(branch, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        pending = Array(pending.prefix(64))
        var next = 0
        // Search siblings before deep branches so an unrelated subtree cannot consume the budget.
        // Metadata only; never choose an unfocused sibling or read its document text.
        for _ in 0..<64 {
            guard inTime() else { return nil }
            if next >= pending.count { break }
            let node = pending[next]; next += 1
            AXUIElementSetMessagingTimeout(node, 0.025)
            if let focused = query(node, kAXFocusedAttribute), CFGetTypeID(focused) == CFBooleanGetTypeID(), CFEqual(focused, kCFBooleanTrue),
               let role = query(node, kAXRoleAttribute) as? String,
               ([kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole] + SelectedCell.roles).contains(role) { return node }
            if let children = query(node, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children.prefix(64 - pending.count)) }
        }
        return markerEditor()
    }
    static func focusedMarkerEditor(_ root: AXUIElement, selected: CFTypeRef? = nil, expectedEditor: AXUIElement? = nil, read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute, parameterized: @MainActor (AXUIElement, String, CFTypeRef) -> CFTypeRef? = parameterizedAttribute, pidOf: @MainActor (AXUIElement) -> pid_t? = processIdentifier, onFailure: (String) -> Void = { _ in }, onDiagnostic: (String) -> Void = { _ in }) -> AXUIElement? {
        func unavailable(_ reason: String) -> AXUIElement? { onDiagnostic("marker_focus_\(reason)"); return nil }
        guard let rootRole = read(root, kAXRoleAttribute) as? String,
              ![kAXApplicationRole, kAXWindowRole, kAXSheetRole, kAXDrawerRole].contains(rootRole) else { return unavailable("no_control_scope") }
        if let subrole = read(root, kAXSubroleAttribute), (subrole as? String) == nil || subrole as? String == kAXSecureTextFieldSubrole { return unavailable("secure_or_invalid_subrole") }
        guard let selected = selected ?? read(root, "AXSelectedTextMarkerRange") else { return unavailable("no_selection_markers") }
        guard CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID() else { onFailure("invalid_selected_markers"); return nil }
        let range = selected as! AXTextMarkerRange
        var editor: AXUIElement?
        // Web selection and marker lookup can be document-wide. Both endpoints
        // must identify one focused text control inside the locked focus branch.
        for marker in [AXTextMarkerRangeCopyStartMarker(range), AXTextMarkerRangeCopyEndMarker(range)] {
            guard let found = parameterized(root, "AXUIElementForTextMarker", marker) else { return unavailable("no_marker_element") }
            guard CFGetTypeID(found) == AXUIElementGetTypeID() else { onFailure("invalid_marker_element"); return nil }
            let leaf = found as! AXUIElement
            AXUIElementSetMessagingTimeout(leaf, 0.025)
            let textRoles = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
            var candidate = leaf
            if !textRoles.contains(read(leaf, kAXRoleAttribute) as? String ?? "") {
                guard let ancestor = read(leaf, "AXEditableAncestor") else { return unavailable("no_editable_ancestor") }
                guard CFGetTypeID(ancestor) == AXUIElementGetTypeID() else { onFailure("invalid_editable_ancestor"); return nil }
                candidate = ancestor as! AXUIElement
                AXUIElementSetMessagingTimeout(candidate, 0.025)
            }
            guard textRoles.contains(read(candidate, kAXRoleAttribute) as? String ?? "") else { return unavailable("no_text_control") }
            if let expectedEditor, !CFEqual(candidate, expectedEditor) { onFailure("selected_markers_outside_element"); return nil }
            guard let focused = read(candidate, kAXFocusedAttribute), CFGetTypeID(focused) == CFBooleanGetTypeID(), CFEqual(focused, kCFBooleanTrue) else { return unavailable("editor_not_focused") }
            guard let pid = pidOf(root), pidOf(leaf) == pid, pidOf(candidate) == pid else { return unavailable("process_mismatch") }
            // AXEditableAncestor preserves semantic ownership even when AXParent
            // skips an ignored text control. The editor must still be in this branch.
            guard isDescendant(candidate, of: root, read: read) else { return unavailable("editor_outside_focus_branch") }
            for node in [leaf, candidate] {
                if let subrole = read(node, kAXSubroleAttribute), (subrole as? String) == nil || subrole as? String == kAXSecureTextFieldSubrole { return unavailable("secure_or_invalid_subrole") }
            }
            for name in [kAXEnabledAttribute, "AXIsEditable"] {
                if let flag = read(candidate, name), CFGetTypeID(flag) != CFBooleanGetTypeID() || !CFEqual(flag, kCFBooleanTrue) { return unavailable("editor_not_enabled_or_editable") }
            }
            if let editor, !CFEqual(editor, candidate) { onFailure("ambiguous_marker_editors"); return nil }
            editor = candidate
        }
        return editor
    }
    static func isDescendant(_ element: AXUIElement, of root: AXUIElement, read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute) -> Bool {
        var current = element, visited = [element]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        for _ in 0..<12 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            if CFEqual(current, root) { return true }
            AXUIElementSetMessagingTimeout(current, 0.025)
            guard let parent = read(current, kAXParentAttribute),
                  ProcessInfo.processInfo.systemUptime < deadline, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            let ancestor = parent as! AXUIElement
            guard !visited.contains(where: { CFEqual($0, ancestor) }) else { return false }
            AXUIElementSetMessagingTimeout(ancestor, 0.025)
            current = ancestor; visited.append(ancestor)
        }
        return ProcessInfo.processInfo.systemUptime < deadline && CFEqual(current, root)
    }
    static func requestAccessibility(_ application: AXUIElement, allowed: () -> Bool, onAttempt: () -> Void,
                                     read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute,
                                     settable: @MainActor (AXUIElement, String) -> (AXError, Bool) = { element, name in
                                         var result: DarwinBoolean = false
                                         let status = AXUIElementIsAttributeSettable(element, name as CFString, &result)
                                         return (status, result.boolValue)
                                     }, set: @MainActor (AXUIElement, String, CFTypeRef) -> AXError = { element, name, value in
                                         AXUIElementSetAttributeValue(element, name as CFString, value)
                                     }) -> String {
        let name = "AXManualAccessibility"
        guard allowed() else { return "guard_changed" }
        let (status, writable) = settable(application, name)
        guard allowed() else { return "guard_changed" }
        guard status == .success, writable else { return "unsupported_\(status.rawValue)" }
        let value = read(application, name)
        guard allowed() else { return "guard_changed" }
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return "invalid_flag" }
        guard CFEqual(value, kCFBooleanFalse) else { return "already_enabled" }
        // A timeout can still have started the provider's timer. Register the
        // attempt before setting; never repeat it or disable this shared flag.
        onAttempt()
        return "requested_\(set(application, name, kCFBooleanTrue).rawValue)"
    }
    static func capture(readText: Bool = true, readSelection: Bool = true, countedSelection: Bool = false, onFailure: (String) -> Void = { _ in }, onCandidate: (NSRunningApplication) -> Void = { _ in }) -> InputTarget? {
        func fail(_ reason: String) -> InputTarget? { onFailure(reason); return nil }
        guard AXIsProcessTrusted() else { return fail("accessibility_not_trusted") }
        guard !IsSecureEventInputEnabled() else { return fail("secure_input_active") }
        var readError = ""
        func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            if status != .success { readError = "\(name):\(status.rawValue)"; return nil }
            readError = "\(name):unexpected_type"; return result
        }
        var focusSearchFailure: String?, markerFocusDetail = ""
        func metadata(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            let result = read(node, name)
            if result == nil, !permitsMissingAttribute(readError, name) { focusSearchFailure = focusSearchFailure ?? readError }
            return result
        }
        func focusedLeaf(_ root: AXUIElement, onScope: (AXUIElement) -> Void = { _ in }) -> AXUIElement? {
            focusedTextDescendant(root, read: metadata, parameterized: { node, name, parameter in
                var result: CFTypeRef?
                let status = AXUIElementCopyParameterizedAttributeValue(node, name as CFString, parameter, &result)
                if status != .success, ![AXError.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented].contains(status) {
                    focusSearchFailure = focusSearchFailure ?? "\(name):\(status.rawValue)"
                }
                return status == .success ? result : nil
            }, onScope: onScope, onFailure: { focusSearchFailure = focusSearchFailure ?? $0 }, onMarkerDiagnostic: { markerFocusDetail = $0 })
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        // Keyboard focus can belong to a nonactivating panel in a different application.
        var focused = read(system, kAXFocusedUIElementAttribute)
        var focusOrigin = "system"
        var pid: pid_t = 0
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            guard AXUIElementGetPid(focused as! AXUIElement, &pid) == .success else { return fail("focused_pid_unavailable") }
        } else {
            guard focused == nil, permitsFocusFallback(readError) else { return fail(readError) }
            if let keyboardApp = read(system, kAXFocusedApplicationAttribute), CFGetTypeID(keyboardApp) == AXUIElementGetTypeID() {
                guard AXUIElementGetPid(keyboardApp as! AXUIElement, &pid) == .success else { return fail("focused_pid_unavailable") }
                focusOrigin = "keyboard_application"
            } else {
                guard permitsMissingAttribute(readError, kAXFocusedApplicationAttribute),
                      let front = NSWorkspace.shared.frontmostApplication else { return fail(readError) }
                pid = front.processIdentifier
                focusOrigin = "frontmost_application"
            }
        }
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return fail("no_keyboard_application") }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return fail("sayvia_is_focused") }
        onCandidate(app)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        // Providers can initialize their native accessibility tree on a role
        // read. This is metadata only and never authorizes a text destination.
        _ = attribute(application, kAXRoleAttribute)
        if focused == nil {
            focused = read(application, kAXFocusedUIElementAttribute)
        }
        if focused == nil, permitsFocusFallback(readError) {
            let missingFocus = readError
            // Search only the keyboard application's focused window, and only accept
            // a control explicitly marked focused. Do not guess a field from its position.
            if let window = read(application, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
                focused = focusedLeaf(window as! AXUIElement)
                if let focusSearchFailure { return fail(focusSearchFailure) }
                if focused == nil { readError = missingFocus }
            } else if !permitsMissingAttribute(readError, kAXFocusedWindowAttribute) { return fail(readError) }
            else { readError = missingFocus }
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return fail("input_control_unavailable:focus_\(focusOrigin):\(readError)")
        }
        var element = focused as! AXUIElement
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(element, &focusedPID) == .success, focusedPID == app.processIdentifier else { return fail("focused_application_changed") }
        let initialRole = metadata(element, kAXRoleAttribute) as? String ?? ""
        if let focusSearchFailure { return fail(focusSearchFailure) }
        let wrapper = ["AXWebArea", kAXGroupRole, kAXUnknownRole, kAXApplicationRole, kAXWindowRole].contains(initialRole)
        if !([kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole] + SelectedCell.roles).contains(initialRole) {
            var searchScope = element
            if let child = focusedLeaf(element, onScope: { searchScope = $0 }) {
                guard AXUIElementGetPid(child, &focusedPID) == .success, focusedPID == pid else { return fail("focused_application_changed") }
                element = child
            } else if wrapper, focusSearchFailure == nil, let candidate = read(application, kAXFocusedUIElementAttribute) {
                guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return fail("invalid_application_focus") }
                let leaf = candidate as! AXUIElement
                guard AXUIElementGetPid(leaf, &focusedPID) == .success, focusedPID == pid else { return fail("focused_application_changed") }
                // The application can retain a different window's stale focus. Only
                // accept its shortcut inside the final narrowed focus branch.
                if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(metadata(leaf, kAXRoleAttribute) as? String ?? ""),
                   isDescendant(leaf, of: searchScope, read: metadata) { element = leaf }
            } else if wrapper, focusSearchFailure == nil, !permitsFocusFallback(readError) { return fail(readError) }
        }
        if let focusSearchFailure { return fail(focusSearchFailure) }
        if markerFocusDetail == "marker_focus_resolved" { focusOrigin += "_marker_editor" }
        // Some editors focus a text child; only walk its ancestors, never choose a sibling field.
        for _ in 0..<12 {
            guard (metadata(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { return fail("secure_text_field") }
            let role = metadata(element, kAXRoleAttribute) as? String ?? ""
            let editable = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) ||
                hasCustomEditingCapability(element, read: metadata) ||
                (["AXWebArea", kAXGroupRole, kAXUnknownRole].contains(role) && hasEditableSelection(element, read: metadata))
            if let focusSearchFailure { return fail(focusSearchFailure) }
            if editable { break }
            guard [kAXGroupRole, kAXStaticTextRole, kAXUnknownRole].contains(role),
                  let parent = metadata(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        guard (metadata(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { return fail("secure_text_field") }
        if let focusSearchFailure { return fail(focusSearchFailure) }
        var cellFailure: String?
        let cell = SelectedCell.capture(in: element, onFailure: { cellFailure = $0 })
        if let cellFailure { return fail(cellFailure) }
        if let cell {
            guard AXUIElementGetPid(cell.element, &focusedPID) == .success, focusedPID == pid else { return fail("cell_application_changed") }
            guard AXUIElementGetPid(cell.container, &focusedPID) == .success, focusedPID == pid else { return fail("cell_application_changed") }
            element = cell.element
        }
        let role = metadata(element, kAXRoleAttribute) as? String ?? "unknown"
        let container = ["AXWebArea", kAXGroupRole, kAXUnknownRole].contains(role)
        let customEditor = hasCustomEditingCapability(element, read: metadata)
        let enabled = metadata(element, kAXEnabledAttribute) as? Bool
        let editable = metadata(element, "AXIsEditable") as? Bool
        if let focusSearchFailure { return fail(focusSearchFailure) }
        guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) || container || customEditor || cell != nil,
              enabled != false, editable != false else {
            return fail("non_text_target:\(app.bundleIdentifier ?? "unknown"):\(role):\(editingDiagnostic(element))\(markerFocusDetail.isEmpty ? "" : ":" + markerFocusDetail)")
        }
        if container {
            let writable = hasEditableSelection(element, read: metadata)
            if let focusSearchFailure { return fail(focusSearchFailure) }
            guard writable else { return fail("non_text_target:\(app.bundleIdentifier ?? "unknown"):\(role)") }
        }
        var windowValue = read(element, kAXWindowAttribute)
        if windowValue == nil {
            guard permitsMissingAttribute(readError, kAXWindowAttribute) else { return fail(readError) }
            if let top = read(element, kAXTopLevelUIElementAttribute) {
                guard CFGetTypeID(top) == AXUIElementGetTypeID() else { return fail("non_window_top_level") }
                let topRole = attribute(top as! AXUIElement, kAXRoleAttribute) as? String
                if topRole == kAXWindowRole { windowValue = top }
                else if ![kAXSheetRole, kAXDrawerRole].contains(topRole ?? "") { return fail("non_window_top_level") }
            } else {
                guard permitsMissingAttribute(readError, kAXTopLevelUIElementAttribute) else { return fail(readError) }
            }
            if windowValue == nil { windowValue = read(application, kAXFocusedWindowAttribute) }
        }
        guard let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return fail(readError) }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(windowValue as! AXUIElement, &windowPID) == .success, windowPID == pid else { return fail("window_application_changed") }
        if let cell {
            let value = readText ? read(element, kAXValueAttribute) as? String : ""
            guard let value, value.utf16.count <= 100_000 else { return fail("cell_text_unavailable") }
            return InputTarget(element: element, pid: pid, appID: app.bundleIdentifier ?? "", value: value,
                               range: NSRange(location: 0, length: value.utf16.count), window: windowValue as! AXUIElement,
                               textSource: "cell_value", captureDetail: "target_cell:focus_\(focusOrigin):selection_single:readback_ready", cell: cell)
        }
        var readingDetail = "", readableDocument: String?, documentPlaceholder: String?
        func unreadable(_ reason: String) -> InputTarget? {
            return InputTarget(element: element, pid: pid, appID: app.bundleIdentifier ?? "", value: readableDocument ?? "", range: NSRange(location: 0, length: 0), window: windowValue as! AXUIElement, readsText: readableDocument != nil, readsSelection: false,
                               textSource: readableDocument == nil ? "value" : "counted_range", textMetadata: readingDetail, placeholder: documentPlaceholder,
                               captureDetail: "target_control:focus_\(focusOrigin):selection_unknown:readback_\(reason)\(readingDetail.isEmpty ? "" : ":" + readingDetail)")
        }
        var selectionFailure: String?
        func readIntegerSelection() -> CFRange? {
            let single = read(element, kAXSelectedTextRangeAttribute)
            if single == nil, !permitsMissingAttribute(readError, kAXSelectedTextRangeAttribute) { selectionFailure = readError; return nil }
            let multiple = read(element, kAXSelectedTextRangesAttribute)
            if multiple == nil, !permitsMissingAttribute(readError, kAXSelectedTextRangesAttribute) { selectionFailure = readError; return nil }
            return selectionRange(single, multiple: multiple, onFailure: { selectionFailure = $0 })
        }
        if !readText {
            _ = readIntegerSelection()
            // Identity-only checks keep hard AX errors (control gone) but not
            // momentary range disagreement: Chromium editors report it mid-typing,
            // which stopped dispatch halfway in Electron chat apps.
            let soft = ["inconsistent_selection_ranges", "multiple_or_invalid_selection_ranges", "invalid_selection_range"]
            if let selectionFailure, !soft.contains(selectionFailure) { return fail(selectionFailure) }
            return InputTarget(element: element, pid: pid, appID: app.bundleIdentifier ?? "", value: "", range: NSRange(location: 0, length: 0), window: windowValue as! AXUIElement, readsText: false)
        }
        let exposedValue = read(element, kAXValueAttribute) as? String
        let valueFailure = readError
        guard exposedValue != nil || permitsMissingAttribute(valueFailure, kAXValueAttribute) else { return fail(valueFailure) }
        guard (exposedValue?.utf16.count ?? 0) <= 100_000 else { return fail("text_too_large") }
        var value = exposedValue ?? ""
        let countValue = read(element, kAXNumberOfCharactersAttribute)
        guard countValue != nil || permitsMissingAttribute(readError, kAXNumberOfCharactersAttribute) else { return fail(readError) }
        let characterCount = countValue.flatMap(nonnegativeInteger)
        guard countValue == nil || characterCount.map({ $0 <= 100_000 }) == true else { return fail("invalid_character_count") }
        var rangeFailure: String?, markedDocumentUnproven = false
        // Read only this focused element. Markers preserve a consistent document
        // representation, but generated placeholder text can occur in it too.
        let markedValue = readSelection ? markedDocument(element, query: { name, parameter in
            var actual: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &actual)
            guard status == .success else {
                if ![AXError.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented].contains(status) { rangeFailure = "\(name):\(status.rawValue)" }
                return nil
            }
            if actual == nil { rangeFailure = "\(name):unexpected_type" }
            return actual
        }, onUnproven: { markedDocumentUnproven = true }, onFailure: { rangeFailure = rangeFailure ?? $0 }) : nil
        if let rangeFailure { return fail(rangeFailure) }
        func stringForRange(_ range: CFRange) -> String? {
            var range = range
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var actual: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &actual)
            guard status == .success else {
                if ![AXError.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented, .illegalArgument].contains(status) { rangeFailure = "AXStringForRange:\(status.rawValue)" }
                return nil
            }
            guard let text = actual as? String, text.utf16.count <= 100_000 else { rangeFailure = "invalid_ranged_text"; return nil }
            return text
        }
        var rangedValue: String?
        if let count = characterCount {
            rangedValue = stringForRange(CFRange(location: 0, length: count))
        }
        // AXValue can be a virtual placeholder without AXPlaceholderValue or character
        // count. A successful full-range read is document evidence, unlike a caret at zero.
        if rangedValue == nil, !value.isEmpty {
            rangedValue = stringForRange(CFRange(location: 0, length: value.utf16.count))
            if rangedValue == nil, value.contains("\n") {
                let alternate = stringForRange(CFRange(location: 0, length: value.replacingOccurrences(of: "\n", with: "").utf16.count))
                // A shorter request is only a coordinate probe, never a full document.
                if alternate?.utf16.elementsEqual(value.replacingOccurrences(of: "\n", with: "").utf16) == true { rangedValue = alternate }
            }
        }
        if let rangeFailure { return fail(rangeFailure) }
        let nativeRange = readIntegerSelection()
        if let selectionFailure { return fail(selectionFailure) }
        var source = ""
        let corroborationCount = !markedDocumentUnproven && [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) ? characterCount : nil
        value = documentValue(exposedValue, rangedValue: rangedValue, markedValue: markedValue, characterCount: corroborationCount, nativeRange: nativeRange, onSource: { source = $0 })
        if !markedDocumentUnproven, exposedValue == nil, rangedValue == nil, markedValue == nil, characterCount != 0 { return unreadable("text_unavailable") }
        var placeholderFailure: String?
        let placeholder = declaredPlaceholder(element, query: { node, name in
            var actual: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, name as CFString, &actual)
            return (status, actual)
        }, onFailure: { placeholderFailure = $0 })
        if let placeholderFailure { return fail(placeholderFailure) }
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) {
            readableDocument = countedDocument(exposedValue, rangedValue: rangedValue, characterCount: characterCount, placeholder: placeholder)
        }
        documentPlaceholder = placeholder
        let metadata = "value_\(exposedValue?.utf16.count ?? -1)_count_\(characterCount ?? -1)_range_\(rangedValue?.utf16.count ?? -1)_markers_\(markedValue?.utf16.count ?? -1)_unproven_markers_\(markedDocumentUnproven ? 1 : 0)_placeholder_\(placeholder?.utf16.count ?? -1)_hintmatch_\(placeholderMatches(value, placeholder: placeholder) ? 1 : 0)"
        readingDetail = metadata + ":integer_\(nativeRange?.location ?? -1)_len_\(nativeRange?.length ?? -1):document_source_\(source)"
        // A locked document-only target never gains selection authority later.
        if !readSelection { return unreadable("selection_not_observed") }
        // A locked counted source still checks selected marker ownership/types
        // when markers recover; the integer shortcut must not bypass them.
        let resolved = resolvedSelection(element, value: value, nativeRange: nativeRange, rangedValue: rangedValue, documentUnproven: markedDocumentUnproven || countedSelection, selectedMarkers: {
            let markers = read(element, "AXSelectedTextMarkerRange")
            if markers == nil, !permitsMissingAttribute(readError, "AXSelectedTextMarkerRange") { rangeFailure = readError }
            return markers
        }, read: { node, name in
            let result = read(node, name)
            if result == nil, !permitsMissingAttribute(readError, name) { rangeFailure = rangeFailure ?? readError }
            return result
        }, query: { name, parameter in
            var result: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result)
            if status != .success, ![AXError.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue, .notImplemented].contains(status) { rangeFailure = rangeFailure ?? "\(name):\(status.rawValue)" }
            if status == .success, result == nil { rangeFailure = rangeFailure ?? "\(name):unexpected_type" }
            return status == .success ? result : nil
        }, onUnproven: { readingDetail += ":" + $0 }, onFailure: { rangeFailure = rangeFailure ?? $0 })
        if let rangeFailure { return fail(rangeFailure) }
        // Marker coordinates can be unavailable while this editor's integer
        // API is coherent. Prove that API independently, without relaxing the
        // marker-owner/type checks above or changing the native selection.
        if resolved == nil || countedSelection, let document = readableDocument {
            let corroborated = corroboratedSelection(element, value: document, rangedValue: rangedValue, characterCount: characterCount,
                                                      nativeRange: nativeRange, placeholder: placeholder, read: { node, name in
                let result = read(node, name)
                if result == nil, !permitsMissingAttribute(readError, name) { rangeFailure = rangeFailure ?? readError }
                return result
            }, stringForRange: stringForRange, selection: readIntegerSelection, onUnproven: { readingDetail += ":" + $0 }, onFailure: { rangeFailure = rangeFailure ?? $0 })
            if let rangeFailure { return fail(rangeFailure) }
            if let selectionFailure { return fail(selectionFailure) }
            if let corroborated {
                return InputTarget(element: element, pid: pid, appID: app.bundleIdentifier ?? "", value: document, range: corroborated,
                                   window: windowValue as! AXUIElement, textSource: "counted_selection", textMetadata: metadata, placeholder: placeholder,
                                   captureDetail: "target_control:focus_\(focusOrigin):selection_integer_corroborated:readback_ready")
            }
        }
        // A locked coordinate source cannot silently switch to another API.
        if countedSelection { return unreadable("counted_selection_unproven") }
        guard let resolved else {
            guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return fail("selection_coordinates_unproven") }
            return unreadable("selection_coordinates_unproven")
        }
        // Container eligibility already proved this claim. Ordinary text roles
        // need no extra setter query for an attribute we do not write.
        return InputTarget(element: element, pid: app.processIdentifier, appID: app.bundleIdentifier ?? app.localizedName ?? "", value: value, range: resolved.range, window: windowValue as! AXUIElement, textSource: source, textMetadata: metadata, placeholder: placeholder,
                           captureDetail: "target_control:focus_\(focusOrigin):selection_\(resolved.source):readback_ready",
                           reportsSelectedTextWritable: container || customEditor)
    }
    static func selectionRange(_ single: CFTypeRef?, multiple: CFTypeRef? = nil, onFailure: (String) -> Void = { _ in }) -> CFRange? {
        func decode(_ value: CFTypeRef) -> CFRange? {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
                  range.location < NSNotFound, range.length < NSNotFound, range.length <= Int.max - range.location else { return nil }
            return range
        }
        var range: CFRange?
        if let single {
            guard let decoded = decode(single) else { onFailure("invalid_selection_range"); return nil }
            range = decoded
        }
        if let multiple {
            guard let ranges = multiple as? [AXValue], ranges.count == 1, let decoded = decode(ranges[0]) else { onFailure("multiple_or_invalid_selection_ranges"); return nil }
            if let range, range.location != decoded.location || range.length != decoded.length { onFailure("inconsistent_selection_ranges"); return nil }
            range = decoded
        }
        return range
    }
    static func resolvedSelection(_ element: AXUIElement, value: String, nativeRange: CFRange?, rangedValue: String?, documentUnproven: Bool = false, selectedMarkers: () -> CFTypeRef?, read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute, pidOf: @MainActor (AXUIElement) -> pid_t? = processIdentifier, query: (String, CFTypeRef) -> CFTypeRef?, onUnproven: (String) -> Void = { _ in }, onFailure: (String) -> Void = { _ in }) -> (range: NSRange, source: String)? {
        // A valid integer range can use different coordinates, or describe text
        // omitted by the integer API. Marker proof stays local to this same editor.
        let integerTextMatches = rangedValue.map { $0.utf16.elementsEqual(value.utf16) || $0.utf16.elementsEqual(value.replacingOccurrences(of: "\n", with: "").utf16) } ?? true
        if !documentUnproven, let nativeRange, integerTextMatches,
           let range = textRange(value, range: NSRange(location: nativeRange.location, length: nativeRange.length), rangedValue: rangedValue),
           Safety.replacement(value, range: range, text: "") != nil { return (range, "integer") }
        guard let range = markedSelection(element, selected: selectedMarkers(), value: value, documentUnproven: documentUnproven, read: read, pidOf: pidOf, query: query, onUnproven: onUnproven, onFailure: onFailure) else { return nil }
        return (range, "markers")
    }
    static func nonnegativeInteger(_ value: CFTypeRef) -> Int? {
        guard CFGetTypeID(value) != CFBooleanGetTypeID(), let number = value as? NSNumber,
              let result = Int(exactly: number.int64Value), result >= 0, result < NSNotFound,
              number.compare(NSNumber(value: result)) == .orderedSame else { return nil }
        return result
    }
    static func attributeIsSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
    static func hasCustomEditingCapability(_ element: AXUIElement, read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute, isSettable: @MainActor (AXUIElement, String) -> Bool = attributeIsSettable) -> Bool {
        guard let role = read(element, kAXRoleAttribute) as? String,
              !([kAXApplicationRole, kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXWebArea", kAXGroupRole, kAXUnknownRole] + SelectedCell.roles).contains(role),
              let editable = read(element, "AXIsEditable"), CFGetTypeID(editable) == CFBooleanGetTypeID(), CFEqual(editable, kCFBooleanTrue) else { return false }
        if let enabled = read(element, kAXEnabledAttribute), CFGetTypeID(enabled) != CFBooleanGetTypeID() || !CFEqual(enabled, kCFBooleanTrue) { return false }
        if let subrole = read(element, kAXSubroleAttribute), (subrole as? String) == nil || subrole as? String == kAXSecureTextFieldSubrole { return false }
        return hasEditableSelection(element, read: read, isSettable: isSettable)
    }
    static func editingDiagnostic(_ element: AXUIElement) -> String {
        let editable = (attribute(element, "AXIsEditable") as? Bool).map { $0 ? "yes" : "no" } ?? "unknown"
        let selected = hasEditableSelection(element)
        return "editable_\(editable):writable_selection_\(selected ? "yes" : "no")"
    }
    static func hasEditableSelection(_ element: AXUIElement, read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute, isSettable: @MainActor (AXUIElement, String) -> Bool = attributeIsSettable) -> Bool {
        guard isSettable(element, kAXSelectedTextAttribute) else { return false }
        return selectionRange(read(element, kAXSelectedTextRangeAttribute)) != nil ||
               selectionRange(nil, multiple: read(element, kAXSelectedTextRangesAttribute)) != nil ||
               read(element, "AXSelectedTextMarkerRange").map { CFGetTypeID($0) == AXTextMarkerRangeGetTypeID() } == true
    }
    static func markedSelection(_ element: AXUIElement, selected: CFTypeRef?, value: String, documentUnproven: Bool = false, read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute, pidOf: @MainActor (AXUIElement) -> pid_t? = processIdentifier, query: (String, CFTypeRef) -> CFTypeRef?, onUnproven: (String) -> Void = { _ in }, onFailure: (String) -> Void = { _ in }) -> NSRange? {
        guard let selected else { return nil }
        func fail(_ reason: String) -> NSRange? { onFailure(reason); return nil }
        guard CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID() else { return fail("invalid_selected_markers") }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        func ask(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { onFailure("marked_selection_deadline"); return nil }
            let result = query(name, parameter)
            guard ProcessInfo.processInfo.systemUptime < deadline else { onFailure("marked_selection_deadline"); return nil }
            return result
        }
        let selectedRange = selected as! AXTextMarkerRange
        let selectedStart = AXTextMarkerRangeCopyStartMarker(selectedRange), selectedEnd = AXTextMarkerRangeCopyEndMarker(selectedRange)
        var ownerFailure: String?, ownerDiagnostic = ""
        let owner = focusedMarkerEditor(element, selected: selected, expectedEditor: element, read: { node, name in
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let result = read(node, name)
            return ProcessInfo.processInfo.systemUptime < deadline ? result : nil
        }, parameterized: { _, name, marker in ask(name, marker) }, pidOf: pidOf, onFailure: { ownerFailure = $0 }, onDiagnostic: { ownerDiagnostic = $0 })
        guard ProcessInfo.processInfo.systemUptime < deadline else { return fail("marked_selection_deadline") }
        if let ownerFailure { return fail(ownerFailure) }
        if owner == nil, ownerDiagnostic == "marker_focus_no_marker_element" { return nil }
        guard let owner, CFEqual(owner, element) else { return fail("selected_markers_outside_element") }
        // An editor can accept native keyboard text while its AX positions are
        // stale. Only valid markers may establish a baseline for confirmation.
        guard validMarkers(selectedRange, query: ask, onFailure: onFailure) == true, !documentUnproven else { return nil }
        guard let full = ask("AXTextMarkerRangeForUIElement", element) else { return nil }
        guard CFGetTypeID(full) == AXTextMarkerRangeGetTypeID() else { return fail("invalid_document_markers") }
        let documentRange = full as! AXTextMarkerRange
        guard validMarkers(documentRange, query: ask, onFailure: onFailure) == true else { return nil }
        let start = AXTextMarkerRangeCopyStartMarker(documentRange), end = AXTextMarkerRangeCopyEndMarker(documentRange)
        func text(_ range: AXTextMarkerRange) -> String? {
            guard let result = ask("AXStringForTextMarkerRange", range) else { return nil }
            guard let text = result as? String, text.utf16.count <= 100_000 else { onFailure("invalid_marker_text"); return nil }
            return text
        }
        guard let fullText = text(documentRange), let prefix = text(AXTextMarkerRangeCreate(nil, start, selectedStart)),
              let selectedText = text(selectedRange), let suffix = text(AXTextMarkerRangeCreate(nil, selectedEnd, end)) else { return nil }
        let fullMatches = fullText.utf16.elementsEqual(value.utf16)
        let partsMatch = (prefix + selectedText + suffix).utf16.elementsEqual(value.utf16)
        if !fullMatches || !partsMatch {
            // These reads cannot distinguish AX representation differences from
            // a changing document. Neither proves a readable insertion baseline.
            let detail = "marker_document_unproven:full_equal_\(fullMatches ? 1 : 0)_parts_equal_\(partsMatch ? 1 : 0):value_\(value.utf16.count)_full_\(fullText.utf16.count)_prefix_\(prefix.utf16.count)_selected_\(selectedText.utf16.count)_suffix_\(suffix.utf16.count)"
            guard ProcessInfo.processInfo.systemUptime < deadline else { return fail("marked_selection_deadline") }
            onUnproven(detail); return nil
        }
        let range = NSRange(location: prefix.utf16.count, length: selectedText.utf16.count)
        guard Safety.replacement(value, range: range, text: "") != nil else { return fail("invalid_marker_selection_range") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return fail("marked_selection_deadline") }
        return range
    }
    static func validMarkers(_ range: AXTextMarkerRange, query: (String, CFTypeRef) -> CFTypeRef?, onFailure: (String) -> Void = { _ in }) -> Bool? {
        for marker in [AXTextMarkerRangeCopyStartMarker(range), AXTextMarkerRangeCopyEndMarker(range)] {
            guard let valid = query("AXTextMarkerIsValid", marker) else { return nil }
            guard CFGetTypeID(valid) == CFBooleanGetTypeID() else { onFailure("invalid_marker_validity"); return nil }
            if !CFEqual(valid, kCFBooleanTrue) { return false }
        }
        return true
    }
    static func markedDocument(_ element: AXUIElement, query: (String, CFTypeRef) -> CFTypeRef?, onUnproven: () -> Void = {}, onFailure: (String) -> Void = { _ in }) -> String? {
        guard let range = query("AXTextMarkerRangeForUIElement", element) else { return nil }
        guard CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { onFailure("invalid_document_markers"); return nil }
        guard validMarkers(range as! AXTextMarkerRange, query: query, onFailure: onFailure) == true else { onUnproven(); return nil }
        guard let result = query("AXStringForTextMarkerRange", range) else { onUnproven(); return nil }
        guard let text = result as? String, text.utf16.count <= 100_000 else { onFailure("invalid_marked_text"); return nil }
        return text
    }
    static func documentValue(_ exposedValue: String?, rangedValue: String?, markedValue: String? = nil, characterCount: Int? = nil, nativeRange: CFRange? = nil, onSource: (String) -> Void = { _ in }) -> String {
        let exposed = exposedValue ?? ""
        let emptyDocument = exposedValue == "" && nativeRange?.location == 0 && nativeRange?.length == 0
        // An empty, valid marker document must not hide independently matching
        // nonempty text. Only the complete counted range can corroborate AXValue.
        // Empty documents also need an actual AXValue and unique integer caret.
        if let markedValue, (!exposed.isEmpty || emptyDocument), characterCount == exposed.utf16.count,
           rangedValue?.utf16.elementsEqual(exposed.utf16) == true,
           markedValue.isEmpty || markedValue.utf16.elementsEqual(exposed.utf16) {
            onSource("value_range"); return exposed
        }
        onSource(rangedValue != nil ? (markedValue != nil ? "range_markers" : "range") : markedValue != nil ? "markers" : "value")
        // A zero-length integer request always reads empty, even for real text.
        // It cannot erase a complete document supplied by the marker API.
        if let markedValue { return markedValue }
        guard let rangedValue, !rangedValue.isEmpty, !rangedValue.utf16.elementsEqual(exposed.replacingOccurrences(of: "\n", with: "").utf16) else { return exposed }
        return rangedValue
    }
    static func countedDocument(_ exposedValue: String?, rangedValue: String?, characterCount: Int?, placeholder: String?) -> String? {
        // This proves nonempty text in this element, without proving any caret
        // coordinates or treating unverified zero values as an empty document.
        guard let exposedValue, !exposedValue.isEmpty, characterCount == exposedValue.utf16.count,
              rangedValue?.utf16.elementsEqual(exposedValue.utf16) == true,
              !placeholderMatches(exposedValue, placeholder: placeholder) else { return nil }
        return exposedValue
    }
    static func corroboratedSelection(_ element: AXUIElement, value: String, rangedValue: String?, characterCount: Int?, nativeRange: CFRange?, placeholder: String?,
                                      read: @MainActor (AXUIElement, String) -> CFTypeRef? = attribute,
                                      stringForRange: (CFRange) -> String?, selection: () -> CFRange?, onUnproven: (String) -> Void = { _ in }, onFailure: (String) -> Void = { _ in }) -> NSRange? {
        func unproven(_ reason: String) -> NSRange? { onUnproven(reason); return nil }
        func fail(_ reason: String) -> NSRange? { onFailure(reason); return nil }
        guard value.utf16.count <= 100_000, countedDocument(value, rangedValue: rangedValue, characterCount: characterCount, placeholder: placeholder) != nil,
              let nativeRange, nativeRange.location >= 0, nativeRange.length >= 0,
              nativeRange.location <= value.utf16.count, nativeRange.length <= value.utf16.count - nativeRange.location else { return unproven("integer_document_unproven") }
        let range = NSRange(location: nativeRange.location, length: nativeRange.length)
        guard Safety.replacement(value, range: range, text: "") != nil else { return unproven("integer_selection_unproven") }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        guard let selectedValue = read(element, kAXSelectedTextAttribute) else { return unproven("integer_selected_text_unavailable") }
        guard let selected = selectedValue as? String else { return fail("invalid_selected_text") }
        let end = nativeRange.location + nativeRange.length
        for part in [CFRange(location: 0, length: nativeRange.location), nativeRange, CFRange(location: end, length: value.utf16.count - end)] {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return unproven("integer_selection_deadline") }
            let expected = (value as NSString).substring(with: NSRange(location: part.location, length: part.length))
            guard let actual = stringForRange(part), actual.utf16.elementsEqual(expected.utf16) else { return unproven("integer_text_parts_unproven") }
        }
        guard selected.utf16.elementsEqual((value as NSString).substring(with: range).utf16) else { return unproven("integer_selected_text_unproven") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return unproven("integer_selection_deadline") }
        let freshRange = selection()
        guard ProcessInfo.processInfo.systemUptime < deadline else { return unproven("integer_selection_deadline") }
        let freshValueObject = read(element, kAXValueAttribute)
        let freshValue = freshValueObject as? String
        if freshValueObject != nil, freshValue == nil { return fail("invalid_text_value") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return unproven("integer_selection_deadline") }
        let freshCountObject = read(element, kAXNumberOfCharactersAttribute)
        let freshCount = freshCountObject.flatMap(nonnegativeInteger)
        if freshCountObject != nil, freshCount == nil { return fail("invalid_character_count") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return unproven("integer_selection_deadline") }
        guard freshRange?.location == nativeRange.location, freshRange?.length == nativeRange.length,
              freshValue?.utf16.elementsEqual(value.utf16) == true, freshCount == characterCount else { return unproven("integer_snapshot_changed") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return unproven("integer_selection_deadline") }
        return range
    }
    static func placeholderMatches(_ value: String, placeholder: String?) -> Bool {
        guard let placeholder, !placeholder.isEmpty else { return false }
        // Some rich editors append one paragraph separator to generated hints.
        // This applies only to an explicitly declared hint, never general text.
        return value.utf16.elementsEqual(placeholder.utf16) || value.utf16.elementsEqual((placeholder + "\n").utf16)
    }
    static func declaredPlaceholder(_ element: AXUIElement, query: (AXUIElement, String) -> (AXError, CFTypeRef?), onFailure: (String) -> Void = { _ in }) -> String? {
        let (status, result) = query(element, kAXPlaceholderValueAttribute)
        guard status == .success else {
            if ![AXError.attributeUnsupported, .noValue, .notImplemented].contains(status) { onFailure("AXPlaceholderValue:\(status.rawValue)") }
            return nil
        }
        guard let text = result as? String, text.utf16.count <= 100_000 else { onFailure("invalid_placeholder"); return nil }
        return text
    }
    var isPlaceholderSnapshot: Bool {
        range == NSRange(location: 0, length: 0) && Self.placeholderMatches(value, placeholder: placeholder)
    }
    func confirmedBaseline(for text: String, after: InputTarget) -> String? {
        guard readsText, readsSelection, matches(after, content: false), after.textSource == textSource else { return nil }
        if let expected = Safety.replacement(value, range: range, text: text), after.value.utf16.elementsEqual(expected.utf16) { return value }
        // No pre-input guess of emptiness: a literal copy of the hint can be real
        // content. Accept its disappearance only with declared placeholder evidence,
        // complete output equality and the exact collapsed final caret.
        guard isPlaceholderSnapshot,
              (after.placeholder == nil || placeholder == after.placeholder), after.value.utf16.elementsEqual(text.utf16),
              after.range == NSRange(location: text.utf16.count, length: 0) else { return nil }
        return ""
    }
    // Rich editors add, drop or merge line
    // breaks and zero-width characters (an empty draft's "\n", a blank line kept
    // as one paragraph break), so presence is judged without them.
    static func looseText(_ value: String) -> String {
        let ignored = Set("\r\n\u{2028}\u{2029}\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{FEFF}".unicodeScalars)
        var scalars = String.UnicodeScalarView(); scalars.append(contentsOf: value.unicodeScalars.filter { !ignored.contains($0) })
        return String(scalars)
    }
    func hasCompleteOutput(_ text: String, after: InputTarget) -> Bool {
        guard readsText, matches(after, content: false), after.textSource == textSource else { return false }
        let looseText = Self.looseText(text), looseBefore = Self.looseText(value), looseAfter = Self.looseText(after.value)
        guard !looseText.isEmpty else { return false }
        if !readsSelection {
            // Only text inside the changed span counts as new output. Existing
            // occurrences and partial edits that reuse old text cannot confirm it.
            guard looseBefore.range(of: looseText, options: .literal) == nil else { return false }
            // ponytail: shared prefixes/suffixes can hide a real edit; keep it
            // and repeated output unconfirmed until a scoped edit notification
            // proves the new span.
            let beforeUnits = Array(looseBefore.utf16), afterUnits = Array(looseAfter.utf16)
            let prefix = zip(beforeUnits, afterUnits).prefix(while: { $0 == $1 }).count
            let suffix = zip(beforeUnits.dropFirst(prefix).reversed(), afterUnits.dropFirst(prefix).reversed()).prefix(while: { $0 == $1 }).count
            let changed = NSRange(location: prefix, length: afterUnits.count - prefix - suffix)
            guard let range = Range(changed, in: looseAfter) else { return false }
            return looseAfter[range].range(of: looseText, options: .literal) != nil
        }
        // The expected document up to those characters: the output is visible at
        // the caret. Still not a preserved baseline or learning evidence.
        if let expected = Safety.replacement(value, range: range, text: text), looseAfter == Self.looseText(expected), looseAfter != looseBefore { return true }
        // A disappeared baseline proves the new text is visible, not that it was
        // a placeholder. Keep it separate from full insertion and learning.
        guard range == NSRange(location: 0, length: 0), !value.isEmpty, !value.utf16.elementsEqual(after.value.utf16) else { return false }
        return after.value.utf16.elementsEqual(text.utf16) && after.range == NSRange(location: text.utf16.count, length: 0)
    }
    static func textRange(_ value: String, range: NSRange, rangedValue: String?) -> NSRange? {
        // Some rich editors count generated paragraph breaks in AXValue but not AX ranges.
        // Convert only when ranged text proves this representation; a break boundary is ambiguous.
        guard value.contains("\n"), let rangedValue, rangedValue.utf16.elementsEqual(value.replacingOccurrences(of: "\n", with: "").utf16) else { return range }
        guard range.location >= 0, range.length >= 0, range.location <= rangedValue.utf16.count,
              range.length <= rangedValue.utf16.count - range.location else { return nil }
        let units = Array(value.utf16)
        func offset(_ index: Int) -> Int? {
            var native = 0
            for (position, unit) in units.enumerated() {
                if native == index { return unit == 10 ? nil : position }
                if unit != 10 { native += 1 }
            }
            return native == index ? units.count : nil
        }
        guard let start = offset(range.location), let end = offset(range.location + range.length) else { return nil }
        return NSRange(location: start, length: end - start)
    }
    static func permitsFocusFallback(_ failure: String) -> Bool {
        permitsMissingAttribute(failure, kAXFocusedUIElementAttribute)
    }
    static func permitsMissingAttribute(_ failure: String, _ name: String) -> Bool {
        [-25212, -25205, -25208].contains { failure == "\(name):\($0)" }
    }
    // Chromium-based editors briefly fail AX reads (kAXErrorFailure/-25200,
    // cannotComplete/-25204) while they re-render after an edit. Such a read
    // proves nothing either way; the next read must re-prove the same target.
    static func transientCaptureFailure(_ failure: String) -> Bool {
        failure.hasSuffix(":\(AXError.failure.rawValue)") || failure.hasSuffix(":\(AXError.cannotComplete.rawValue)")
    }
    static func readbackUnavailable(_ reason: String) -> Bool {
        reason.hasPrefix("capture_") || reason.hasPrefix("focus_capture") || reason.hasSuffix("_unavailable")
    }
    static func permitsCaptureRetry(_ failure: String) -> Bool {
        failure == "no_input_target" || failure == "invalid_selection_range" ||
        failure == "focused_application_changed" || failure == "window_application_changed" ||
        failure == "focus_search_deadline" || failure.hasPrefix("input_control_unavailable:") ||
        failure.hasSuffix(":\(AXError.cannotComplete.rawValue)")
    }
    func recapture(readText: Bool = true, onFailure: (String) -> Void = { _ in }) -> InputTarget? {
        guard var current = Self.capture(readText: readText && readsText, readSelection: readsSelection, countedSelection: textSource == "counted_selection", onFailure: onFailure) else { return nil }
        if !readText || !readsText { current.readsText = readsText; current.readsSelection = readsSelection }
        return current
    }
    func identityDifference(from other: InputTarget) -> String? {
        if pid != other.pid { return "application_changed" }
        if !CFEqual(window, other.window) { return "window_changed" }
        if !CFEqual(element, other.element) { return "element_changed" }
        if let cell, other.cell.map({ cell.matches($0) }) != true { return "cell_selection_changed" }
        if cell == nil, other.cell != nil { return "target_capability_changed" }
        return nil
    }
    func difference(from other: InputTarget) -> String? {
        if let change = identityDifference(from: other) { return change }
        if readsText != other.readsText || (readsText && readsSelection != other.readsSelection) { return "target_capability_changed" }
        if textSource != other.textSource { return "text_source_changed" }
        if !value.utf16.elementsEqual(other.value.utf16) { return "text_changed" }
        if placeholderDiffers(other) { return "placeholder_changed" }
        if readsSelection, range != other.range { return "selection_changed" }
        return nil
    }
    func matches(_ other: InputTarget, content: Bool = true) -> Bool {
        identityDifference(from: other) == nil && readsText == other.readsText && (!readsText || readsSelection == other.readsSelection) && (!content || (textSource == other.textSource && value.utf16.elementsEqual(other.value.utf16) && (!readsSelection || range == other.range) && !placeholderDiffers(other)))
    }
    // A hint matters only while AXValue may be that hint. Some chat editors'
    // empty reply box rotate an unexposed hint without changing the target; the
    // equal value and selection checks still apply.
    private func placeholderDiffers(_ other: InputTarget) -> Bool {
        placeholder != other.placeholder && (Self.placeholderMatches(value, placeholder: placeholder) || Self.placeholderMatches(other.value, placeholder: other.placeholder))
    }
    var context: String {
        if !readsText || !readsSelection || cell != nil { return "" }
        return "应用：\(appID)\n" + Safety.nearbyText(value, range: range)
    }
    var identity: InputIdentity {
        InputIdentity(pid: pid, window: CFHash(window), element: CFHash(element), container: cell.map { CFHash($0.container) }, row: cell?.row, column: cell?.column)
    }
    var capability: String { cell != nil ? "unique_writable_cell" : readsText ? (readsSelection ? "readable_text" : "readable_document") : "opaque_text" }
    func insert(_ text: String, isValid: () -> Bool, onDiagnostic: (String) -> Void = { _ in }, capture: (() -> InputTarget?)? = nil, dispatch: ((CGEvent) -> Void)? = nil, setAttribute: ((AXUIElement, String, String) -> AXError)? = nil) async -> String {
        await deliver(text, isValid: isValid, onDiagnostic: onDiagnostic, capture: capture, dispatch: dispatch, setAttribute: setAttribute).status
    }
    func deliver(_ text: String, isValid: () -> Bool, onDiagnostic: (String) -> Void = { _ in }, capture: (() -> InputTarget?)? = nil, dispatch: ((CGEvent) -> Void)? = nil, setAttribute: ((AXUIElement, String, String) -> AXError)? = nil, trace: LatencyRecorder? = nil, readbackRevision: (() -> UInt64)? = nil, pasteboard: NSPasteboard? = nil, onPasteSession: (ClipboardPaste.Session, Bool) -> Void = { _, _ in }, onEvidence: (InputDeliveryEvidence) -> Void = { _ in }) async -> InputDeliveryEvidence {
        var evidence = InputDeliveryEvidence(capture: InputCaptureEvidence(capability: capability, identity: identity))
        var pasteSession: ClipboardPaste.Session?
        func finish(_ status: String, _ stage: String? = nil, _ reason: String? = nil) -> InputDeliveryEvidence {
            evidence.status = status; evidence.failureStage = stage; evidence.failureReason = reason
            // The target consumed the paste: the user's clipboard can return now.
            if status == "inserted" || status == "input_text_present" { pasteSession?.provider.landed = true }
            evidence.confirmation = status == "inserted" ? "preserved_document" : status == "input_text_present" ? "complete_output" : status == "input_dispatched" ? "dispatch_only" : "none"
            onEvidence(evidence); return evidence
        }
        var writeDetail = ""
        func diagnose(_ reason: String) { onDiagnostic([captureDetail, writeDetail, reason].filter { !$0.isEmpty }.joined(separator: " · ")) }
        var captureFailure = ""
        func currentTarget(readText: Bool = true) -> InputTarget? {
            captureFailure = ""
            if let capture { return capture() }
            return recapture(readText: readText, onFailure: { captureFailure = $0; diagnose($0) })
        }
        // Names only the changed property (never text) so a refused write can be diagnosed.
        func changeReason(_ stage: String, _ current: InputTarget?) -> String {
            guard isValid() else { return "\(stage)_changed:invalidated" }
            guard let current else { return "\(stage)_changed:recapture_failed:\(captureFailure.isEmpty ? "unknown" : captureFailure)" }
            return "\(stage)_changed:" + (difference(from: current) ?? "capability_flags")
        }
        func readbackFailure(_ reason: String) -> InputDeliveryEvidence {
            diagnose("readback_stopped:\(reason)")
            // Not being able to read the field is no evidence the text is missing:
            // report it sent, like a control without readback. Only a read that shows
            // the text absent, another window/app or user interaction stays uncertain.
            return finish(Self.readbackUnavailable(reason) ? "input_dispatched" : "input_unconfirmed", "readback", reason)
        }
        diagnose("capture_ready")
        let preflight = trace?.begin("input_preflight_capture")
        let current = isValid() ? currentTarget() : nil
        if let preflight { trace?.end(preflight, outcome: current.map { matches($0) } == true ? "completed" : "failed") }
        guard isValid(), let current, matches(current) else { diagnose(changeReason("preflight", current)); return finish("saved_only", "preflight_capture", "target_or_interaction_changed") }
        evidence.checkpoints.append("preflight_capture_passed")
        let expected: String?
        if readsText && !readsSelection { expected = nil }
        else {
            guard let replacement = Safety.replacement(value, range: range, text: text) else { return finish("saved_only", "prepare", "invalid_selection") }
            guard !replacement.utf16.elementsEqual(value.utf16) else { return finish("unchanged") }
            expected = replacement
        }
        // Ordinary editors use the established text-event path even when their
        // AX provider advertises writable selected text but silently ignores it.
        let singleWrite = cell != nil
        writeDetail = singleWrite ? "route_ax_cell_value" : "route_pid_unicode"
        evidence.route = singleWrite ? "ax_cell_value" : "pid_unicode"
        let chunks = Safety.textChunks(text)
        evidence.plannedSegments = singleWrite ? 1 : chunks.count
        guard singleWrite ? Safety.canCommitText(text) : Safety.canType(chunks) else { diagnose("unsafe_text_control_or_oversized_character"); return finish("saved_only", "prepare", "unsafe_text") }
        if cell != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("=") {
            diagnose("cell_formula_not_text"); return finish("saved_only", "prepare", "cell_formula_not_text")
        }
        let preparation = trace?.begin("input_event_preparation")
        var preparationCompleted = false
        defer { if let preparation { trace?.end(preparation, outcome: preparationCompleted ? "completed" : "failed") } }
        var events: [[CGEvent]] = []
        if !singleWrite {
            if dispatch == nil, !CGPreflightPostEventAccess() { diagnose("unicode_post_access_missing"); return finish("saved_only", "prepare", "event_access_missing") }
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return finish("saved_only", "prepare", "event_source_failed") }
            for chunk in chunks {
                var pair: [CGEvent] = []
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return finish("saved_only", "prepare", "event_creation_failed") }
                    chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    event.flags = []; event.setIntegerValueField(.eventSourceUserData, value: Hotkeys.insertionEventTag)
                    pair.append(event)
                }
                events.append(pair)
            }
        }
        preparationCompleted = true
        if let preparation { trace?.end(preparation) }
        let preDispatchCapture = trace?.begin("input_pre_dispatch_capture")
        let finalTarget = isValid() ? currentTarget() : nil
        if let preDispatchCapture { trace?.end(preDispatchCapture, outcome: finalTarget.map { matches($0) } == true ? "completed" : "failed") }
        guard isValid(), let finalTarget, matches(finalTarget), isValid() else { diagnose(changeReason("pre_dispatch", finalTarget)); return finish("saved_only", "pre_dispatch_capture", "target_or_interaction_changed") }
        evidence.checkpoints.append("pre_dispatch_capture_passed")
        // Full-document AX reads can outlive a programmatic focus change while
        // observer callbacks wait on MainActor. Recheck identity after those reads.
        guard isValid(), let focused = currentTarget(readText: false), matches(focused, content: false), isValid() else {
            return finish("saved_only", "pre_dispatch_focus", "target_or_interaction_changed")
        }
        evidence.checkpoints.append("pre_dispatch_focus_passed")
        var observedRevision = readbackRevision?()
        let dispatchSpan = trace?.begin("input_dispatch")
        defer { if let dispatchSpan { trace?.end(dispatchSpan, outcome: evidence.dispatchedSegments == evidence.plannedSegments ? "completed" : "interrupted") } }
        // Text controls paste first (user decision, 2026-10-07): one Command-V from a
        // temporary clipboard that the caller restores. Text events remain the
        // route whenever the clipboard cannot be borrowed and returned intact.
        var pasted = false
        if !singleWrite, let board = pasteboard {
            var skipped: String?
            if IsSecureEventInputEnabled() { skipped = "secure_input" }
            else if ClipboardPaste.pending != nil { skipped = "previous_restore_pending" }
            else if ClipboardPaste.holdsMedia(board) { skipped = "clipboard_media" }
            else if let saved = ClipboardPaste.snapshot(board) {
                if ClipboardPaste.concealed(saved) { skipped = "clipboard_concealed" }
                else if let session = ClipboardPaste.begin(text, saved: saved, to: board) {
                    writeDetail = "route_paste_restore"; evidence.route = "paste_restore"; evidence.plannedSegments = 1
                    guard isValid(), let focused = currentTarget(readText: false), matches(focused, content: false), isValid() else {
                        ClipboardPaste.restore(session, to: board)
                        return finish("saved_only", "pre_dispatch_focus", "target_or_interaction_changed")
                    }
                    evidence.status = "dispatching"; evidence.dispatchAttempted = true; evidence.checkpoints.append("dispatch_started"); onEvidence(evidence)
                    let posted = ClipboardPaste.commandV(pid: pid, post: dispatch)
                    pasteSession = session; onPasteSession(session, posted)
                    guard posted else { evidence.dispatchAttempted = false; return finish("saved_only", "dispatch", "paste_event_creation_failed") }
                    evidence.dispatchedSegments = 1; onEvidence(evidence); pasted = true
                } else { skipped = "clipboard_write_failed" }
            } else { skipped = "clipboard_snapshot_unavailable" }
            if let skipped { evidence.checkpoints.append("paste_skipped_" + skipped) }
        }
        if pasted {
        } else if singleWrite {
            // A verified cell receives one value operation. An error may follow
            // a write, so this branch must never retry via text events.
            evidence.status = "dispatching"; evidence.dispatchAttempted = true; evidence.checkpoints.append("dispatch_started"); onEvidence(evidence)
            let status = setAttribute?(element, kAXValueAttribute, text) ?? AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            guard status == .success else { diagnose("single_write_unconfirmed:\(status.rawValue)"); return finish("input_unconfirmed", "dispatch", "attribute_error_\(status.rawValue)") }
            evidence.dispatchedSegments = 1; onEvidence(evidence)
            diagnose("single_write_dispatched")
        } else {
            // No pasteboard access. Bind events to the captured process and never retry a partial dispatch.
            for (index, pair) in events.enumerated() {
                // Let the main run loop deliver focus notifications between chunks.
                // Keep each down/up pair together and recheck before sending more.
                if index > 0 {
                    do { try await Task.sleep(nanoseconds: 1_000_000) }
                    catch { return finish("input_unconfirmed", "dispatch", "cancelled_between_segments") }
                }
                if index > 0 {
                    guard isValid(), let current = currentTarget(readText: false), matches(current, content: false), isValid() else { return finish("input_unconfirmed", "dispatch", "target_or_interaction_changed") }
                } else if !isValid() { return finish("saved_only", "pre_dispatch", "cancelled") }
                if evidence.dispatchAttempted != true { evidence.status = "dispatching"; evidence.dispatchAttempted = true; evidence.checkpoints.append("dispatch_started"); onEvidence(evidence) }
                for event in pair { if let dispatch { dispatch(event) } else { event.postToPid(pid) } }
                evidence.dispatchedSegments += 1; onEvidence(evidence)
            }
        }
        if let dispatchSpan { trace?.end(dispatchSpan) }
        evidence.checkpoints.append("dispatch_complete")
        guard isValid() else { return finish("input_unconfirmed", "post_dispatch", "cancelled_or_interaction_changed") }
        if !readsText { diagnose("\(pasted ? "paste" : "unicode")_dispatched_no_text_readback"); return finish("input_dispatched") }
        // Reading after every 20 UTF-16 units truncates editors that update AX asynchronously.
        // Send one guarded sequence, then verify the complete result without retrying it.
        var last = current
        let readback = trace?.begin("input_readback")
        defer { if let readback { trace?.end(readback, outcome: evidence.status) } }
        evidence.checkpoints.append("readback_started")
        // A paste lands in one step but its target reads the clipboard asynchronously.
        let deadline = ProcessInfo.processInfo.systemUptime + (pasted ? 1.0 : 0.5)
        var unavailable: String?, everReadable = false
        // An unreadable field already ends as sent. A key or click while waiting on
        // it (often Enter to send) adds no evidence the text is missing; only an
        // interruption after a readable snapshot stays uncertain.
        func interrupted() -> InputDeliveryEvidence {
            guard !everReadable, let unavailable, Self.readbackUnavailable(unavailable) else { return readbackFailure("cancelled_or_interaction_changed") }
            diagnose("readback_stopped:interrupted_while_\(unavailable)"); return finish("input_dispatched", "readback", unavailable)
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            let revision = readbackRevision?()
            // A scoped system change is a prompt to read, never delivery proof.
            // Polling remains necessary for editors that omit notifications.
            if revision != observedRevision { await Task.yield() }
            else { do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return finish("input_unconfirmed", "readback", "cancelled") } }
            observedRevision = revision
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard isValid() else { return interrupted() }
            let recaptured = currentTarget()
            guard isValid() else { return recaptured == nil ? interrupted() : readbackFailure("cancelled_or_interaction_changed") }
            guard let after = recaptured else {
                if Self.transientCaptureFailure(captureFailure) { unavailable = "capture_" + captureFailure; continue }
                return readbackFailure("capture_failed:" + (captureFailure.isEmpty ? "unavailable" : captureFailure))
            }
            // Chromium editors briefly report another element for the same field;
            // reading proves nothing then, and confirmation still needs a later match.
            if let change = identityDifference(from: after) { if change == "element_changed" { unavailable = change; continue }; return readbackFailure(change) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            // Text IPC may outlive a focus change while AX notifications await
            // MainActor. Prove the same concrete focus again, without body reads.
            let focus = currentTarget(readText: false)
            guard isValid() else { return readbackFailure("cancelled_or_interaction_changed") }
            guard let focused = focus else {
                if Self.transientCaptureFailure(captureFailure) { unavailable = "focus_capture_" + captureFailure; continue }
                return readbackFailure("focus_capture_failed:" + (captureFailure.isEmpty ? "unavailable" : captureFailure))
            }
            if let change = identityDifference(from: focused) { if change == "element_changed" { unavailable = "focus_" + change; continue }; return readbackFailure("focus_" + change) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if !matches(after, content: false) || textSource != after.textSource {
                // A temporarily missing proof is not a different field. Keep
                // the original source and baseline; never use this snapshot to
                // confirm delivery, learn or dispatch another event.
                guard cell == nil else { return readbackFailure("target_capability_changed") }
                unavailable = !matches(after, content: false) ? "target_capability_unavailable" : "text_source_unavailable"
                let checkpoint = "readback_" + unavailable!
                if !evidence.checkpoints.contains(checkpoint) { evidence.checkpoints.append(checkpoint); onEvidence(evidence) }
                continue
            }
            unavailable = nil; everReadable = true
            last = after
            // Full expected document equality proves delivery and preservation of the
            // surrounding text. A delayed caret update is not a failed insertion.
            if let baseline = confirmedBaseline(for: text, after: after) {
                diagnose("text_readback_confirmed:source_\(textSource):before_\(baseline.utf16.count):sent_\(text.utf16.count):after_\(after.value.utf16.count):placeholder_removed_\(baseline != value ? 1 : 0):before_\(textMetadata):after_\(after.textMetadata)")
                return finish("inserted")
            }
        }
        if let unavailable { return readbackFailure(unavailable) }
        // Give complete preservation the whole readback budget before reporting
        // only output presence. Never infer an empty baseline or retry the write.
        if isValid(), hasCompleteOutput(text, after: last) {
            diagnose("text_present_baseline_unconfirmed:source_\(textSource):before_\(value.utf16.count):sent_\(text.utf16.count):after_\(last.value.utf16.count):before_\(textMetadata):after_\(last.textMetadata)")
            return finish("input_text_present")
        }
        // Where the expected and actual documents part, by character kind only (no
        // text): readbacks one unit short in some editors need this to name the cause.
        func kind(_ unit: UInt16?) -> String {
            guard let unit else { return "end" }
            switch unit {
            case 0x0A, 0x0D, 0x2028, 0x2029: return "newline"
            case 0x20, 0x09, 0xA0, 0x3000: return "space"
            case 0x200B...0x200F, 0xFEFF, 0xFFFC: return "invisible"
            case 0x3001, 0x3002, 0xFF0C, 0xFF01, 0xFF1F, 0xFF1A, 0xFF1B, 0x2C, 0x2E, 0x21, 0x3F: return "punctuation"
            default: return unit < 0x80 ? "ascii" : "other"
            }
        }
        let expectedUnits = Array((expected ?? "").utf16), actualUnits = Array(last.value.utf16)
        let shared = zip(expectedUnits, actualUnits).prefix(while: { $0 == $1 }).count
        let tail = zip(expectedUnits.dropFirst(shared).reversed(), actualUnits.dropFirst(shared).reversed()).prefix(while: { $0 == $1 }).count
        let split = expected == nil ? "" : ":diff_prefix_\(shared)_suffix_\(tail)_expected_\(kind(expectedUnits.dropFirst(shared).first))_actual_\(kind(actualUnits.dropFirst(shared).first))"
        diagnose("text_readback_unconfirmed\(last.value == value && last.textSource == textSource ? ":no_observed_text_change" : "")\(split):expected_\(expected?.utf16.count ?? -1)_at_\(readsSelection ? range.location + text.utf16.count : -1):actual_\(last.value.utf16.count)_at_\(readsSelection ? last.range.location : -1)_len_\(readsSelection ? last.range.length : -1):source_\(textSource)_to_\(last.textSource):before_\(textMetadata):after_\(last.textMetadata)")
        return finish("input_unconfirmed", "readback", last.value == value && last.textSource == textSource ? "no_observed_text_change" : "incomplete_expected_document")
    }

}

// Pure event routing also lets the self-check verify down/up suppression without posting keys.
struct HotkeyState {
    private var fnDown = false
    private var spaceDown = false
    private var globeDown = false
    private var globeDeadline: UInt64 = 0
    mutating func route(type: CGEventType, key: Int64, flags: CGEventFlags, repeated: Bool, useFn: Bool, timestamp: UInt64 = 0) -> (consume: Bool, trigger: Bool) {
        // This keyboard emits a separate 179 down/up pair for the Globe action,
        // after Fn flagsChanged. Consume only the companion of an owned Fn press.
        if key == 179 {
            if type == .keyUp { let owned = globeDown; globeDown = false; return (owned, false) }
            if type == .keyDown {
                let plain = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
                if globeDown { return (true, false) }
                if useFn && plain && (fnDown || (globeDeadline > 0 && timestamp <= globeDeadline)) {
                    globeDown = true; globeDeadline = 0; return (true, false)
                }
            }
        }
        if type == .flagsChanged, key == 63 {
            let down = flags.contains(.maskSecondaryFn)
            let owned = fnDown
            if !down {
                fnDown = false
                if owned { globeDeadline = timestamp &+ 2_000_000_000 }
                return (owned, false)
            }
            guard useFn else { return (false, false) }
            let plain = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
            if !owned && plain { fnDown = true; globeDeadline = timestamp &+ 2_000_000_000; return (true, true) }
            return (owned, false)
        }
        if key == 49 {
            if type == .keyUp { let owned = spaceDown; spaceDown = false; return (owned, false) }
            if type == .keyDown, flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == [.maskCommand, .maskAlternate] {
                let trigger = !spaceDown && !repeated; spaceDown = true; return (true, trigger)
            }
        }
        return (false, false)
    }
}

// The worker owns its run loop; it never waits for AppKit, audio, AX or the main actor.
final class HotkeyWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var state = HotkeyState()
    private var enabledFn: Bool
    private var serial: UInt64 = 0
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopping = false
    private var done = false
    private var fnEvents = 0
    private var swallowed = 0
    private var interruptions = 0
    private var systemEvents: [String] = []
    private var controlEvents: [String] = []
    private var lastFnTime: UInt64 = 0
    private var escapeArmed = false
    private var escapeDown = false
    var escape: (@MainActor @Sendable () -> Void)?
    private let action: @MainActor @Sendable (UInt64) -> Void
    private let interaction: @MainActor @Sendable (CGEventType, Int64, CGEventFlags, UInt64) -> Void
    init(useFn: Bool, action: @escaping @MainActor @Sendable (UInt64) -> Void,
         interaction: @escaping @MainActor @Sendable (CGEventType, Int64, CGEventFlags, UInt64) -> Void) {
        enabledFn = useFn; self.action = action; self.interaction = interaction
    }
    var finished: Bool { lock.withLock { done } }
    var active: Bool { lock.withLock { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false } }
    var interactionSerial: UInt64 { lock.withLock { serial } }
    var diagnostic: String { lock.withLock { "Fn事件 \(fnEvents) · 已拦截 \(swallowed) · 监听中断 \(interruptions) · 系统事件 \(systemEvents.joined(separator: ",")) · 控制事件 \(controlEvents.joined(separator: ","))" } }
    func setFn(_ value: Bool) { lock.withLock { enabledFn = value } }
    /// Esc cancels only while Sayvia is recording or processing; otherwise it passes through untouched.
    func setEscape(_ armed: Bool) { lock.withLock { escapeArmed = armed; if !armed { escapeDown = false } } }
    func start() {
        let thread = Thread { self.run() }
        thread.name = "Sayvia hotkeys"; thread.qualityOfService = .userInteractive; thread.start()
    }
    func stop() {
        let loop = lock.withLock { stopping = true; return runLoop }
        if let loop {
            // A queued block also handles stop arriving just before CFRunLoopRun starts.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }
    private func run() {
        let loop = CFRunLoopGetCurrent()!
        let types: [CGEventType] = [CGEventType(rawValue: 14)!, .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let createdTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotkeyWorker>.fromOpaque(pointer).takeUnretainedValue().receive(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else {
            lock.withLock { done = true }; return
        }
        CFRunLoopAddSource(loop, source, .commonModes)
        let shouldRun = lock.withLock { () -> Bool in
            tap = createdTap; runLoop = loop; return !stopping
        }
        if shouldRun { CGEvent.tapEnable(tap: createdTap, enable: true); CFRunLoopRun() }
        CGEvent.tapEnable(tap: createdTap, enable: false)
        CFMachPortInvalidate(createdTap)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        lock.withLock { tap = nil; runLoop = nil; done = true }
    }
    func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let currentTap = lock.withLock { () -> CFMachPort? in
                interruptions += 1; serial &+= 1; state = HotkeyState(); return stopping ? nil : tap
            }
            if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // System-defined events carry media/system controls, not typed characters.
        // Observe only; no broad suppression of unrelated system shortcuts.
        if type.rawValue == 14 {
            if let native = NSEvent(cgEvent: event) {
                let description = "\(native.subtype.rawValue):\(native.data1)"
                lock.withLock {
                    guard lastFnTime > 0, event.timestamp >= lastFnTime, event.timestamp - lastFnTime <= 2_000_000_000 else { return }
                    systemEvents.append(description)
                    if systemEvents.count > 4 { systemEvents.removeFirst() }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Hotkeys.insertionEventTag { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode), flags = event.flags
        if key == 53, type == .keyDown || type == .keyUp {
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let consumed = lock.withLock { () -> Bool in
                if type == .keyDown, escapeArmed, flags.intersection(modifiers).isEmpty { escapeDown = true; return true }
                if type == .keyUp, escapeDown { escapeDown = false; return true }
                return false
            }
            if consumed {
                if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0, let escape { DispatchQueue.main.async { escape() } }
                return nil
            }
        }
        let snapshot = lock.withLock { () -> (Bool, Bool, Bool, UInt64) in
            guard !stopping else { return (false, false, false, serial) }
            if type == .keyDown, lastFnTime > 0, event.timestamp >= lastFnTime,
               event.timestamp - lastFnTime <= 2_000_000_000 {
                // Record control categories only, never ordinary typed characters.
                let kind = key == 63 ? "fn_key" : key >= 123 ? "special_\(key)" : key == 49 && flags.contains(.maskCommand) && flags.contains(.maskControl) ? "emoji_chord" : key == 14 && flags.contains(.maskSecondaryFn) ? "fn_e" : "other"
                controlEvents.append("\(kind)/\(flags.rawValue)/pid\(event.getIntegerValueField(.eventSourceUnixProcessID))")
                if controlEvents.count > 4 { controlEvents.removeFirst() }
            }
            let route = state.route(type: type, key: key, flags: flags, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, useFn: enabledFn, timestamp: event.timestamp)
            if type == .flagsChanged, key == 63 { lastFnTime = event.timestamp; fnEvents += 1; if route.consume { swallowed += 1 } }
            // Viewport scrolling does not by itself move a text insertion point.
            // Focus still gets checked between text events and during readback.
            let interacted = !route.consume && type != .flagsChanged && type != .keyUp && type != .scrollWheel
            if interacted { serial &+= 1 }
            return (route.consume, route.trigger, interacted, serial)
        }
        if snapshot.1 { DispatchQueue.main.async { self.action(snapshot.3) } }
        if snapshot.2 { DispatchQueue.main.async { self.interaction(type, key, flags, snapshot.3) } }
        return snapshot.0 ? nil : Unmanaged.passUnretained(event)
    }
}

struct HotkeySnapshot: Equatable {
    let generation: UUID
    let serial: UInt64
    func invalidates(_ baseline: HotkeySnapshot, current: HotkeySnapshot) -> Bool {
        generation == current.generation && generation == baseline.generation && serial > baseline.serial
    }
}

@MainActor
final class Hotkeys {
    nonisolated static let insertionEventTag: Int64 = 0x536179766961
    var action: ((HotkeySnapshot) -> Void)?
    var interaction: ((CGEventType, Int64, CGEventFlags, HotkeySnapshot) -> Void)?
    var useFn = true { didSet { worker?.setFn(useFn) } }
    var escape: (() -> Void)?
    var escapeArmed = false { didSet { worker?.setEscape(escapeArmed) } }
    private var worker: HotkeyWorker?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast
    var active: Bool { worker?.active ?? false }
    var snapshot: HotkeySnapshot { HotkeySnapshot(generation: generation, serial: worker?.interactionSerial ?? 0) }
    var diagnostic: String { worker?.diagnostic ?? "监听尚未启动" }
    deinit { worker?.stop() }
    func start() {
        guard worker == nil || worker?.finished == true, Date().timeIntervalSince(lastAttempt) >= 1 else { return }
        lastAttempt = Date()
        guard AXIsProcessTrusted() else { return }
        let nextGeneration = UUID(); generation = nextGeneration
        let next = HotkeyWorker(useFn: useFn, action: { [weak self] serial in self?.action?(HotkeySnapshot(generation: nextGeneration, serial: serial)) },
                                interaction: { [weak self] type, key, flags, serial in self?.interaction?(type, key, flags, HotkeySnapshot(generation: nextGeneration, serial: serial)) })
        next.escape = { [weak self] in self?.escape?() }
        next.setEscape(escapeArmed)
        worker = next; next.start()
    }
}
