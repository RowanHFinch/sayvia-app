import SwiftUI
import AppKit
import Security

@main
@MainActor
enum SayviaMain {
    static func main() async {
        if CommandLine.arguments.contains("--check-credentials") {
            // The login Keychain ignores LAContext's UI policy; these separate diagnostic processes must never prompt.
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.count > index + 1 {
            // Build-time helper for scripts/build-app.sh; draws the icon from the same geometry as the app.
            do { try SayviaAppIcon.renderIconset(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) } catch { fputs("Icon rendering failed.\n", stderr); exit(1) }
        } else if CommandLine.arguments.contains("--self-test") {
            do { try await SafetyChecks.run() } catch { fputs("Self-check failed: \(error)\n", stderr); exit(1) }
        } else if let index = CommandLine.arguments.firstIndex(of: "--preview-ui") {
            #if DEBUG
            let args = CommandLine.arguments
            let page = args.count > index + 1 ? args[index + 1] : "首页"
            let snapshot = args.firstIndex(of: "--snapshot").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
            do { try SafetyChecks.previewUI(page: page, snapshot: snapshot) } catch { fputs("UI preview failed.\n", stderr); exit(1) }
            #else
            fputs("UI preview is available only in a debug build.\n", stderr); exit(1)
            #endif
        } else if CommandLine.arguments.contains("--check-credentials") {
            do {
                let config = try Store().load(Configuration.self, kind: "configuration").first ?? Configuration()
                for (role, endpoint) in [("stt", config.sttURL), ("rewrite", config.rewriteURL)] {
                    let account = Keychain.account(endpoint: endpoint)
                    let stored = try Keychain.exists(account)
                    do { let key = try Keychain.read(account, allowUI: false); print("\(role): stored=\(stored) readable=\(!key.isEmpty)") }
                    catch { print("\(role): stored=\(stored) readable=false · \(error.localizedDescription)") }
                }
            } catch { fputs("Credential status check failed (private data omitted).\n", stderr); exit(1) }
        } else { SayviaApp.main() }
    }
}

struct SayviaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Sayvia", id: "main") { MainWindowContent(delegate: delegate).environmentObject(model) }
            .windowStyle(.hiddenTitleBar).defaultSize(mainWindowDefaultSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { delegate.showMainWindow(NSApp); model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuContent(delegate: delegate).environmentObject(model)
        } label: { Image(nsImage: SayviaBrand.menuBarImage) }
    }
}
struct MainWindowContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    let delegate: AppDelegate
    var body: some View {
        MainView().background(MainWindowRegistration(delegate: delegate)).onAppear {
            delegate.attach(model)
            delegate.openMainWindow = { openWindow(id: "main") }
        }
    }
}
struct MainWindowRegistration: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> WindowView { WindowView(delegate: delegate) }
    func updateNSView(_ view: WindowView, context: Context) {}
    final class WindowView: NSView {
        weak var delegate: AppDelegate?
        private var observers: [NSObjectProtocol] = []
        init(delegate: AppDelegate) { self.delegate = delegate; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let window else { return }
            delegate?.mainWindow = window; window.isMovableByWindowBackground = true
            // AppKit re-lays out the title bar on these events, so the buttons are placed again afterwards.
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeTrafficLights() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.placeTrafficLights() }
        }
        /// Centers the window buttons inside the inset sidebar's rounded top-left corner
        /// instead of AppKit's default spot, which straddles the sidebar edge.
        func placeTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton), let mini = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton), let titlebar = close.superview, let container = titlebar.superview else { return }
            let height: CGFloat = 52, centerFromTop: CGFloat = 8 + 18, left: CGFloat = 8 + 14
            let pitch = max(20, mini.frame.minX - close.frame.minX)
            let target = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            // Skip work when nothing moved; layout churn here shows up as stutter while resizing.
            if container.frame != target { container.frame = target; titlebar.frame = container.bounds }
            for (index, button) in [close, mini, zoom].enumerated() {
                let origin = NSPoint(x: left + CGFloat(index) * pitch, y: height - centerFromTop - button.frame.height / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    let delegate: AppDelegate
    var body: some View {
        Text(L(model.message))
        Button(L(model.phase == "recording" ? "结束录音" : "开始录音")) { model.toggle() }.disabled(model.busy && model.phase != "recording")
        if model.busy { Button("取消") { model.cancel() } }
        Divider()
        Button("打开 Sayvia") { delegate.showMainWindow(NSApp) }
        Button("设置…") { delegate.showMainWindow(NSApp); model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
        Divider(); Button("退出") { NSApp.terminate(nil) }
    }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var mainWindow: NSWindow?
    var openMainWindow: (() -> Void)?
    private var panel: NSPanel?
    private weak var model: AppModel?
    private var timer: Timer?
    private var hiding = false
    func attach(_ model: AppModel) {
        guard panel == nil else { return }; self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 112), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear
        // The system window shadow traces the soft SwiftUI shadow and draws a halo around the pill.
        panel.hasShadow = false; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VoiceBar().environmentObject(model))
        self.panel = panel
        model.onActivityChange = { [weak self] in self?.updatePanel() }
        updatePanel()
    }
    private func updatePanel() {
        guard let model, let panel else { return }
        timer?.invalidate(); timer = nil
        if model.busy || Date() < model.resultVisibleUntil {
            if !panel.isVisible || hiding, let screen = NSScreen.main {
                // Rise and fade in; also reverses a hide that is still animating.
                hiding = false
                let origin = NSPoint(x: screen.visibleFrame.midX-220, y: screen.visibleFrame.minY+36)
                if !panel.isVisible { panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 12)); panel.orderFrontRegardless() }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1; panel.animator().setFrameOrigin(origin)
                }
            }
            if !model.busy {
                timer = Timer.scheduledTimer(withTimeInterval: max(0.01, model.resultVisibleUntil.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePanel() }
                }
            }
        } else if panel.isVisible, !hiding {
            hiding = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18; context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY - 8))
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hiding else { return }
                    self.hiding = false; panel.orderOut(nil)
                }
            })
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model?.cancel(); ClipboardPaste.restorePending(); return .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The recording panel can be visible while the main window is closed or hidden.
        // Reopen the registered main window regardless of AppKit's visible-window flag.
        showMainWindow(sender)
        return false
    }
    func showMainWindow(_ sender: NSApplication) {
        sender.unhide(nil)
        if let mainWindow {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
        } else { openMainWindow?() }
        sender.activate(ignoringOtherApps: true)
    }
}
/// Floating HUD near the bottom of the screen: a ×/✓ pill while recording with
/// hover hints above the buttons, a text pill with a progress sweep while processing, and a
/// dark toast for results that need attention. One background morphs between the states.
/// Successful delivery shows nothing; the model clears it immediately.
struct VoiceBar: View {
    @EnvironmentObject var model: AppModel
    @State private var hint: HUDHint?
    var body: some View {
        let state = stateKey
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ZStack {
                if let hint { HUDTooltip(hint: hint).frame(maxWidth: .infinity, alignment: hint == .cancel ? .leading : .trailing).transition(.opacity.combined(with: .offset(y: 4))) }
            }.frame(width: 160, height: 32, alignment: .bottom)
            content
                .background(HUDBackground(radius: state == "toast" ? 16 : 20, toast: state == "toast"))
                .compositingGroup().shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state)
        }
        .padding(.bottom, 12)
        .frame(width: 440, height: 112)
        .environment(\.colorScheme, .dark)
        .onChange(of: state) { _, _ in hint = nil }
    }
    private var stateKey: String { model.phase == "recording" ? "recording" : model.busy ? "processing" : "toast" }
    @ViewBuilder private var content: some View {
        if model.phase == "recording" {
            HUDRecordingPill(level: model.volume, degraded: model.message.contains("暂不可用"),
                             remaining: model.recordingRemaining, cancel: { model.cancel() }, finish: { model.finish() }, hint: $hint)
                .transition(.opacity)
        } else if model.busy {
            HUDProcessingPill(text: model.message).transition(.opacity)
        } else {
            HUDToast(kind: toastKind, text: model.message, action: toastAction, close: persistent ? { model.resultVisibleUntil = .distantPast } : nil,
                     until: model.resultVisibleUntil == .distantFuture ? nil : model.resultVisibleUntil)
                .id(model.message).transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
    private var persistent: Bool { !model.recoveryText.isEmpty }
    private var toastKind: HUDToast.Kind {
        if model.learnedTerm != nil { return .learned }
        if !model.recoveryText.isEmpty || model.message.contains("部分文字") { return .warning }
        if model.message.contains("失败") || model.message.contains("不可用") || model.error != nil { return .failure }
        return .info
    }
    private var toastAction: (String, () -> Void)? {
        if model.learnedTerm != nil { return ("撤销", { model.undoLearnedTerm() }) }
        if !model.recoveryText.isEmpty { return ("复制", { model.copy(model.recoveryText); model.message = "已复制，请在目标输入框按 ⌘V" }) }
        return nil
    }
}

enum HUDHint { case cancel, finish }

/// Shared HUD surface; its size and corner radius animate when the content changes.
private struct HUDBackground: View {
    let radius: CGFloat, toast: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: toast ? 0.24 : 0.2))
            .overlay(RoundedRectangle(cornerRadius: radius - 1, style: .continuous).fill(toast ? Color(white: 0.11) : .black).padding(1))
    }
}

/// Hover hint above a HUD button: "取消" and "完成 fn".
struct HUDTooltip: View {
    let hint: HUDHint
    var body: some View {
        HStack(spacing: 8) {
            Text(L(hint == .cancel ? "取消" : "完成")).font(.system(size: 13, weight: .medium))
            Text(hint == .cancel ? "esc" : "fn").font(.system(size: 12, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1).background(Color(white: 0.29), in: RoundedRectangle(cornerRadius: 5))
        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

private struct HUDCircleButton: View {
    let icon: String, label: String, light: Bool
    let action: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(light ? Color.black : .white)
                .frame(width: 30, height: 30).background(light ? Color.white : Color(white: 0.29), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(L(label)).onHover(perform: onHover)
    }
}

struct HUDRecordingPill: View {
    let level: Double, degraded: Bool
    let remaining: Int?
    let cancel: () -> Void, finish: () -> Void
    var hint: Binding<HUDHint?> = .constant(nil)
    var body: some View {
        HStack(spacing: 12) {
            HUDCircleButton(icon: "xmark", label: "取消并保留录音", light: false, action: cancel) { inside in withAnimation(.easeOut(duration: 0.15)) { hint.wrappedValue = inside ? .cancel : (hint.wrappedValue == .cancel ? nil : hint.wrappedValue) } }
            if degraded { Circle().fill(Color.orange).frame(width: 7, height: 7).accessibilityLabel("服务暂不可用，结束后保留音频") }
            Group {
                // Below the speech floor, a dotted line says "listening, but quiet".
                if level < 0.04 { HStack(spacing: 4) { ForEach(0..<9, id: \.self) { _ in Circle().fill(.white.opacity(0.85)).frame(width: 3, height: 3) } } }
                else { Waveform(level: level) }
            }.frame(width: 72, height: 22).accessibilityLabel("输入音量").accessibilityValue("\(Int(level * 100))%")
            if let remaining { Text("\(remaining) 秒后结束").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
            HUDCircleButton(icon: "checkmark", label: "完成录音", light: true, action: finish) { inside in withAnimation(.easeOut(duration: 0.15)) { hint.wrappedValue = inside ? .finish : (hint.wrappedValue == .finish ? nil : hint.wrappedValue) } }
        }.padding(5)
    }
}

/// "正在整理" pill; the lighter sweep eases toward the end without claiming completion.
struct HUDProcessingPill: View {
    let text: String
    @State private var started = Date()
    var body: some View {
        Text(L(text)).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            .padding(.horizontal, 26).frame(height: 40)
            .background {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let fraction = 1 - exp(-context.date.timeIntervalSince(started) / 2.5)
                    GeometryReader { proxy in Color.white.opacity(0.16).frame(width: proxy.size.width * fraction) }
                }.clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous)).padding(1)
            }
            .onAppear { started = Date() }
    }
}

struct HUDToast: View {
    enum Kind { case info, learned, warning, failure }
    let kind: Kind, text: String
    let action: (String, () -> Void)?
    var close: (() -> Void)? = nil
    /// When the toast hides on its own; drives the countdown hairline.
    var until: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var shake: CGFloat = 0
    @State private var opened = Date()
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
                // Learned words spin in; other icons pop (motion.learn / motion.success).
                .rotationEffect(.degrees(entered || kind != .learned || reduceMotion ? 0 : -90))
                .scaleEffect(entered || reduceMotion ? 1 : 0.5)
            Text(L(text)).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
            if let action {
                Button(L(action.0), action: action.1).buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7).background(Color(white: 0.29), in: Capsule())
            }
            if let close { Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.6)) }.buttonStyle(.plain).accessibilityLabel("关闭提示") }
        }
        .padding(.leading, 15).padding(.trailing, action == nil && close == nil ? 17 : 7).padding(.vertical, 7).frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if let until, until > opened {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let left = max(0, until.timeIntervalSince(context.date) / until.timeIntervalSince(opened))
                    GeometryReader { proxy in Capsule().fill(.white.opacity(0.35)).frame(width: max(0, (proxy.size.width - 32) * left), height: 1.5).frame(maxWidth: .infinity) }
                }.frame(height: 1.5).padding(.bottom, 3).accessibilityHidden(true)
            }
        }
        .offset(x: shake)
        .onAppear {
            opened = Date()
            guard !reduceMotion else { withAnimation(.easeOut(duration: 0.2)) { entered = true }; return }
            withAnimation(.spring(response: 0.45, dampingFraction: kind == .learned ? 0.55 : 0.6)) { entered = true }
            if kind == .failure {
                // ±5pt three times, then settle (motion.shake); failures only.
                Task { @MainActor in
                    for x in [-5.0, 5, -4, 3, -1.5, 0] { withAnimation(.easeInOut(duration: 0.07)) { shake = x }; try? await Task.sleep(for: .milliseconds(70)) }
                }
            }
        }
    }
    private var icon: String { switch kind { case .info: "info.circle"; case .learned: "sparkle"; case .warning: "exclamationmark.triangle"; case .failure: "exclamationmark.circle" } }
    private var tint: Color { switch kind { case .info: Color(red: 0.37, green: 0.55, blue: 1); case .learned: Theme.accent; case .warning: .orange; case .failure: Color(red: 1, green: 0.27, blue: 0.23) } }
}

/// Standalone HUD surface for previews and onboarding, matching the live panel.
struct HUDSurface<Content: View>: View {
    var toast = false
    @ViewBuilder var content: Content
    var body: some View { content.background(HUDBackground(radius: toast ? 16 : 20, toast: toast)).compositingGroup().shadow(color: .black.opacity(0.22), radius: 6, y: 3) }
}

/// White bars driven by the input level; time only adds motion, not signal.
struct Waveform: View {
    let level: Double
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<12, id: \.self) { i in
                    let wobble = 0.55 + 0.45 * sin(t * 9 + Double(i) * 1.3)
                    let envelope = 1 - abs(Double(i) - 5.5) / 7
                    Capsule().fill(.white).frame(width: 2.5, height: max(3, 22 * min(1, level * 1.6) * wobble * envelope))
                }
            }.frame(maxHeight: .infinity)
        }
    }
}

// First-open size follows the screen like common desktop apps: about two thirds
// of the usable width and 82% of the height, never below the window minimum.
// macOS remembers any size the user picks afterwards.
var mainWindowDefaultSize: CGSize {
    let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    return CGSize(width: min(1600, max(1100, screen.width * 0.68)), height: min(1100, max(760, screen.height * 0.82)))
}
