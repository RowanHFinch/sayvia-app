import AppKit
import ApplicationServices
import Carbon

enum FocusChange: String {
    case application, focus, window, selection, value
}

// A notification belongs to one subscription lifetime, even after A → B → A.
// Old callbacks never authorize input or revive an earlier field.
struct FocusObservationState {
    private(set) var pid: pid_t = 0
    private(set) var generation = UUID()
    private(set) var received: UInt64 = 0
    private(set) var rebindings: UInt64 = 0
    mutating func bind(_ next: pid_t) -> Bool {
        guard next != pid else { return false }
        pid = next; generation = UUID(); rebindings &+= 1
        return true
    }
    mutating func receive(pid: pid_t, generation: UUID) -> Bool {
        guard pid > 0, pid == self.pid, generation == self.generation else { return false }
        received &+= 1; return true
    }
}

@MainActor
private final class FocusObserverContext {
    weak var owner: FocusObserver?
    let generation: UUID
    init(owner: FocusObserver, generation: UUID) { self.owner = owner; self.generation = generation }
}

private let focusObserverCallback: AXObserverCallback = { observer, element, name, context in
    guard let context else { return }
    // This observer's source is installed only on the main run loop.
    MainActor.assumeIsolated {
        let bridge = Unmanaged<FocusObserverContext>.fromOpaque(context).takeUnretainedValue()
        bridge.owner?.receive(observer, element: element, name: name as String, generation: bridge.generation)
    }
}

// Self-checks exercise native subscription/recovery paths without observing
// another application or adding a run-loop source to the user's session.
struct FocusObserverHooks {
    var now: () -> Double
    var allowed: () -> Bool
    var pid: () -> pid_t?
    var capture: () -> InputTarget?
    var create: (pid_t, AXObserverCallback) -> (AXError, AXObserver?)
    var subscribe: (AXObserver, AXUIElement, String, UnsafeMutableRawPointer) -> AXError
    var unsubscribe: (AXObserver, AXUIElement, String) -> Void
    var attach: (AXObserver) -> Void
    var detach: (AXObserver) -> Void
}

@MainActor
final class FocusObserver {
    var onChange: ((FocusChange) -> Void)?
    var onStatus: ((String) -> Void)?
    private var state = FocusObservationState()
    private var observer: AXObserver?
    private var context: FocusObserverContext?
    private var application: AXUIElement?
    private var field: AXUIElement?
    private var applicationNotifications: [String] = []
    private var fieldNotifications: [String] = []
    private var failures: [String: Int32] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var lastRefresh = -Double.infinity
    private var retryAfter = -Double.infinity
    private var refreshing = false
    private var status = "焦点监听待命"
    private let testHooks: FocusObserverHooks?

    init(testHooks: FocusObserverHooks? = nil) { self.testHooks = testHooks }

    var diagnostic: String {
        let errors = failures.keys.sorted().map { "\($0)_\(failures[$0]!)" }.joined(separator: ",")
        return "ax_observer:app_\(applicationNotifications.count):field_\(fieldNotifications.count):received_\(state.received):rebind_\(state.rebindings):errors_\(errors.isEmpty ? "none" : errors)"
    }
    func start() {
        if workspaceTokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Activation is a hint: a nonactivating panel can own
                        // keyboard focus in a different process.
                        self.refresh(force: true, notify: false)
                        self.onChange?(.application)
                    }
                })
            }
        }
        refresh()
    }
    func stop() {
        detach()
        _ = state.bind(0)
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        publish("焦点监听待命")
    }
    func refresh(force: Bool = false, notify: Bool = true) {
        guard !refreshing else { return }
        let now = testHooks?.now() ?? ProcessInfo.processInfo.systemUptime
        guard force || now - lastRefresh >= 0.5 else { return }
        lastRefresh = now; refreshing = true
        defer { refreshing = false }
        guard testHooks?.allowed() ?? (AXIsProcessTrusted() && !IsSecureEventInputEnabled()) else {
            let changed = state.bind(0)
            detach(); publish("焦点监听暂停，写入前仍会核对权限与目标")
            if changed, notify { onChange?(.focus) }
            return
        }
        let pid = (testHooks.map { $0.pid() } ?? Self.keyboardPID()) ?? 0
        let changed = state.bind(pid)
        if changed { detach(); retryAfter = -Double.infinity }
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            detach(); publish("焦点监听待命")
            if changed, notify { onChange?(.focus) }
            return
        }
        if observer == nil, now >= retryAfter {
            var created: AXObserver?
            let result: AXError
            if let testHooks { (result, created) = testHooks.create(pid, focusObserverCallback) }
            else { result = AXObserverCreate(pid, focusObserverCallback, &created) }
            if result == .success, let created {
                failures["create"] = nil
                observer = created; application = AXUIElementCreateApplication(pid)
                context = FocusObserverContext(owner: self, generation: state.generation)
                AXUIElementSetMessagingTimeout(application!, 0.025)
                for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
                    if subscribe(created, element: application!, name: name) { applicationNotifications.append(name) }
                }
                if let testHooks { testHooks.attach(created) }
                else { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes) }
            } else {
                failures["create"] = result.rawValue; retryAfter = now + 2
            }
        }
        // Only focused-control metadata is read here, never its document text.
        // The input pipeline always performs its own fresh full capture.
        // Do not cache a field before creation succeeds: recovery must register
        // the same field even when it has not changed since the failed attempt.
        let current = observer == nil ? nil : (testHooks.map { $0.capture() } ?? InputTarget.capture(readText: false))
        let next = current.flatMap { $0.pid == pid ? ($0.cell?.container ?? $0.element) : nil }
        let fieldChanged = !Self.same(field, next)
        if fieldChanged {
            removeFieldNotifications(); field = next
            if let observer, let next {
                AXUIElementSetMessagingTimeout(next, 0.025)
                let names = current?.cell == nil ? [kAXSelectedTextChangedNotification, kAXValueChangedNotification] : [kAXSelectedCellsChangedNotification, kAXSelectedChildrenChangedNotification, kAXValueChangedNotification]
                for name in names {
                    if subscribe(observer, element: next, name: name) { fieldNotifications.append(name) }
                }
            }
        }
        publish(applicationNotifications.isEmpty ? "焦点变化通知未提供，使用即时读取" : "焦点变化监听已启动")
        if (changed || fieldChanged), notify { onChange?(.focus) }
    }
    private func subscribe(_ observer: AXObserver, element: AXUIElement, name: String) -> Bool {
        guard let context else { return false }
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let result = testHooks?.subscribe(observer, element, name, pointer) ?? AXObserverAddNotification(observer, element, name as CFString, pointer)
        if result == .success { failures[name] = nil; return true }
        failures[name] = result.rawValue; return false
    }
    fileprivate func receive(_ observed: AXObserver, element: AXUIElement, name: String, generation: UUID) {
        guard let observer, CFEqual(observed, observer) else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              state.receive(pid: pid, generation: generation) else { return }
        let kind: FocusChange
        switch name {
        case kAXFocusedUIElementChangedNotification: kind = .focus
        case kAXFocusedWindowChangedNotification: kind = .window
        case kAXSelectedTextChangedNotification, kAXSelectedCellsChangedNotification, kAXSelectedChildrenChangedNotification: kind = .selection
        case kAXValueChangedNotification: kind = .value
        default: return
        }
        if kind == .selection || kind == .value {
            guard let field, CFEqual(element, field) else { return }
        } else { refresh(force: true, notify: false) }
        onChange?(kind)
    }
    private static func same(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }
    static func keyboardPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        for name in [kAXFocusedUIElementAttribute, kAXFocusedApplicationAttribute] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(system, name as CFString, &value)
            if result == .success {
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                var pid: pid_t = 0
                guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success, pid > 0 else { return nil }
                return pid
            }
            guard [.noValue, .attributeUnsupported, .notImplemented].contains(result) else { return nil }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    private func publish(_ next: String) {
        guard next != status else { return }
        status = next; onStatus?(next)
    }
    private func removeFieldNotifications() {
        if let observer, let field {
            for name in fieldNotifications { unsubscribe(observer, element: field, name: name) }
        }
        fieldNotifications.removeAll(); field = nil
    }
    private func unsubscribe(_ observer: AXObserver, element: AXUIElement, name: String) {
        if let testHooks { testHooks.unsubscribe(observer, element, name) }
        else { AXObserverRemoveNotification(observer, element, name as CFString) }
    }
    private func detach() {
        removeFieldNotifications()
        if let observer {
            if let application {
                for name in applicationNotifications { unsubscribe(observer, element: application, name: name) }
            }
            if let testHooks { testHooks.detach(observer) }
            else { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
        observer = nil; context = nil; application = nil; applicationNotifications.removeAll(); failures.removeAll()
    }
    deinit {
        // No callback tasks are enqueued; removing the main run-loop source and
        // workspace registrations ends the lifetime of the unretained context.
        if let observer {
            if let testHooks { testHooks.detach(observer) }
            else { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
    }
}
