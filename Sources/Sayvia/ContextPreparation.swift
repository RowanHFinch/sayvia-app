import AppKit
import ApplicationServices
import Carbon

// Ephemeral only. Never serialize nearby text or hold an AX target for input.
struct ContextReference: Sendable {
    var appID: String
    var context: String
    var identity: InputIdentity
    var visibleCharacters = 0
}
struct ContextPreparationResult: Sendable {
    var reference: ContextReference?
    var outcome: String
}
struct ContextCaptureHooks {
    var allowed: () -> Bool
    var query: (AXUIElement, String) -> (AXError, CFTypeRef?)
    var pid: (AXUIElement) -> pid_t?
    var appID: (pid_t) -> String
}

private final class ContextCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ContextPreparationResult, Never>?
    private var result: ContextPreparationResult?
    func attach(_ continuation: CheckedContinuation<ContextPreparationResult, Never>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(returning: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: ContextPreparationResult) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: result)
    }
}

// A synchronous AX call cannot be forcibly interrupted. Keep it off the main
// actor, release the awaiting pipeline at its budget, discard late data, and
// admit at most one reader so a stalled provider cannot build up a queue.
final class OptionalContextReader: @unchecked Sendable {
    static let shared = OptionalContextReader()
    private let lock = NSLock()
    private var busy = false
    private let queue = DispatchQueue(label: "io.github.rowanhfinch.sayvia.optional-context", qos: .userInitiated)
    private func acquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard !busy else { return false }; busy = true; return true }
    private func release() { lock.lock(); busy = false; lock.unlock() }
    func read(budget: TimeInterval = 0.12, visibleText: Bool = false, capture: (@Sendable (Double) -> ContextReference?)? = nil) async -> ContextPreparationResult {
        guard !Task.isCancelled else { return ContextPreparationResult(outcome: "cancelled") }
        guard acquire() else { return ContextPreparationResult(outcome: "reader_busy") }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        let completion = ContextCompletion()
        let timeout = DispatchWorkItem { completion.finish(ContextPreparationResult(outcome: "deadline")) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budget, execute: timeout)
        queue.async { [self] in
            defer { release() }
            let reference = capture?(deadline) ?? (capture == nil ? Self.capture(deadline: deadline, visibleText: visibleText) : nil)
            let expired = ProcessInfo.processInfo.systemUptime >= deadline
            completion.finish(ContextPreparationResult(reference: expired ? nil : reference, outcome: expired ? "deadline" : (reference == nil ? "unavailable" : "prepared")))
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { completion.attach($0) }
        } onCancel: { completion.finish(ContextPreparationResult(outcome: "cancelled")) }
    }
    static func capture(deadline: Double, hooks: ContextCaptureHooks? = nil, visibleText: Bool = false) -> ContextReference? {
        func allowed() -> Bool { hooks?.allowed() ?? (AXIsProcessTrusted() && !IsSecureEventInputEnabled()) }
        func pidOf(_ node: AXUIElement) -> pid_t? {
            if let hooks { return hooks.pid(node) }
            var pid: pid_t = 0; return AXUIElementGetPid(node, &pid) == .success ? pid : nil
        }
        guard allowed() else { return nil }
        var failed = false
        func query(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard !failed, ProcessInfo.processInfo.systemUptime < deadline else { failed = true; return nil }
            AXUIElementSetMessagingTimeout(node, 0.015)
            var value: CFTypeRef?
            let status: AXError
            if let hooks { (status, value) = hooks.query(node, name) }
            else { status = AXUIElementCopyAttributeValue(node, name as CFString, &value) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { failed = true; return nil }
            if status == .success { return value }
            if ![AXError.attributeUnsupported, .noValue, .notImplemented].contains(status) { failed = true }
            return nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let system = AXUIElementCreateSystemWide()
        guard let root = element(query(system, kAXFocusedUIElementAttribute)) else { return nil }
        var field = root, visited = [root]
        for _ in 0..<8 {
            guard query(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
            guard let next = element(query(field, kAXFocusedUIElementAttribute)), !CFEqual(next, field) else { break }
            guard !visited.contains(where: { CFEqual($0, next) }) else { return nil }
            visited.append(next); field = next
        }
        let role = query(field, kAXRoleAttribute) as? String ?? ""
        guard query(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              query(field, kAXEnabledAttribute) as? Bool != false else { return nil }
        if !([kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] + SelectedCell.roles).contains(role) {
            guard ["AXWebArea", kAXGroupRole, kAXUnknownRole].contains(role) else { return nil }
            var writable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &writable) == .success, writable.boolValue else { return nil }
        }
        guard let pid = pidOf(field), pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              let window = element(query(field, kAXWindowAttribute)) ?? element(query(field, kAXTopLevelUIElementAttribute)),
              query(window, kAXRoleAttribute) as? String == kAXWindowRole,
              pidOf(window) == pid else { return nil }
        let app = hooks?.appID(pid) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let identity = InputIdentity(pid: pid, window: CFHash(window), element: CFHash(field))
        // The window title (page title, chat, document or mail subject) often names
        // the people and terms being dictated, and is the only hint when the field
        // itself cannot be read. It goes to the cleanup model like nearby text.
        let title = (query(window, kAXTitleAttribute) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        let header = "应用：\(app)" + (title.isEmpty ? "" : "\n窗口：\(title)")
        // Text shown in the same window (the chat thread above
        // the box, the mail being answered) names the people and terms being
        // dictated. Rewrite path only, bounded by count and time, never the field
        // itself or secure text; a slow window just yields less.
        func screenText() -> String {
            let until = deadline - 0.08
            func read(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
                guard ProcessInfo.processInfo.systemUptime < until else { return nil }
                AXUIElementSetMessagingTimeout(node, 0.015)
                var value: CFTypeRef?
                let status: AXError
                if let hooks { (status, value) = hooks.query(node, name) }
                else { status = AXUIElementCopyAttributeValue(node, name as CFString, &value) }
                return status == .success ? value : nil
            }
            // Browsers and Electron apps: start at the page, not tabs and toolbars.
            var start = window, node = field
            for _ in 0..<40 {
                guard let parent = element(read(node, kAXParentAttribute)), !CFEqual(parent, window) else { break }
                if read(parent, kAXRoleAttribute) as? String == "AXWebArea" { start = parent; break }
                node = parent
            }
            var texts: [String] = [], visited = 0
            func walk(_ node: AXUIElement, depth: Int) {
                guard depth < 50, visited < 3000, ProcessInfo.processInfo.systemUptime < until, !CFEqual(node, field) else { return }
                visited += 1
                let role = read(node, kAXRoleAttribute) as? String ?? ""
                // Nothing under a password field is read, whatever its children claim to be.
                if role != kAXStaticTextRole, read(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return }
                if [kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
                   let text = (read(node, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, texts.last != text {
                    texts.append(String(text.prefix(2000)))
                }
                for child in read(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
            }
            walk(start, depth: 0)
            // ponytail: keeps the last 2000 characters (newest chat lines sit near the
            // box); rank by distance to the field if long pages lose the relevant part.
            return String(texts.joined(separator: "\n").suffix(2000))
        }
        // The checked reference stands on its own; screen text only uses the time
        // left, so a slow window can never cost the title or nearby text.
        func withScreen(_ base: ContextReference) -> ContextReference? {
            guard visibleText else { return base }
            let screen = screenText()
            guard allowed() else { return nil }
            guard !screen.isEmpty else { return base }
            var result = base
            result.context = (base.context.isEmpty ? header : base.context) + "\n屏幕文字：\n" + screen; result.visibleCharacters = screen.count
            return result
        }
        func metadataOnly() -> ContextReference? {
            guard let stillFocused = element(query(system, kAXFocusedUIElementAttribute)), CFEqual(root, stillFocused), !failed, allowed() else { return nil }
            return withScreen(ContextReference(appID: app, context: title.isEmpty ? "" : header, identity: identity))
        }
        // Keep application-scoped personalization independent of readable text
        // and integer caret support. Grid metadata never authorizes cell input.
        if SelectedCell.roles.contains(role) {
            guard let stillFocused = element(query(system, kAXFocusedUIElementAttribute)), CFEqual(root, stillFocused), !failed, allowed() else { return nil }
            return ContextReference(appID: app, context: title.isEmpty ? "" : header, identity: identity)
        }
        guard let value = query(field, kAXValueAttribute) as? String,
              let selection = query(field, kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID() else { return metadataOnly() }
        let ax = selection as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range),
              Safety.replacement(value, range: NSRange(location: range.location, length: range.length), text: "") != nil else { return metadataOnly() }
        let placeholder = query(field, "AXPlaceholderValue") as? String
        let context = placeholder == value ? (title.isEmpty ? "" : header) : header + "\n" + Safety.nearbyText(value, range: NSRange(location: range.location, length: range.length))
        guard let stillFocused = element(query(system, kAXFocusedUIElementAttribute)), CFEqual(root, stillFocused),
              !failed, allowed(), ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return withScreen(ContextReference(appID: app, context: context, identity: identity))
    }
}
