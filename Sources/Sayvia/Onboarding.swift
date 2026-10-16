import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices

/// First-run flow: consent, the user's own provider key, permissions with live status, then one real dictation.
/// Consent is saved at the end of step 1 so step 3 can record.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int
    init(step: Int = 1) { _step = State(initialValue: step) }
    @State private var consent = false
    @State private var retention = 0
    @State private var mic = false
    @State private var trust = false
    @State private var hotkeyActive = false
    @State private var tryStarted = Date.distantFuture
    @State private var provider = Provider.bailianBeijing
    @State private var workspace = ""
    @State private var key = ""
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(1...4, id: \.self) { i in Capsule().fill(i <= step ? Color.primary : Color.primary.opacity(0.15)).frame(width: i == step ? 20 : 6, height: 6) }
                    Text("\(step) / 4").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).padding(.leading, 4)
                }.animation(.spring(response: 0.35, dampingFraction: 0.8), value: step).padding(.bottom, 24)
                Group {
                    switch step {
                    case 1: welcome
                    case 2: service
                    case 3: permissions
                    default: tryIt
                    }
                }.transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
            }.padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 28).frame(width: 400, alignment: .leading)
            demo.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { ZStack { Theme.stage; DotGrid()
                    RadialGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0)], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 260)
                    RadialGradient(colors: [Color(red: 0.4, green: 0.55, blue: 0.9).opacity(0.14), .clear], center: UnitPoint(x: 0.7, y: 0.75), startRadius: 0, endRadius: 220) } }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).padding(8)
        }
        .frame(width: 900, height: 580).background(Theme.canvas).tint(.primary)
        .onAppear { retention = model.config.retentionDays; refresh() }
        .onReceive(poll) { _ in if step == 3 { refresh() } }
        .interactiveDismissDisabled(!model.config.onboardingDone)
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            SayviaLogo(size: 44)
            Text("说出来，\n不必打字").font(.system(size: 32, weight: .heavy)).tracking(-0.5).lineSpacing(2).padding(.top, 16).padding(.bottom, 10)
            Text("在任何应用的输入框里按一下 fn 开始说话，再按一下结束，整理好的文字就写在光标处。").font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 11) {
                feature("waveform", "去掉口头禅、改正口误，保留原意和数字")
                feature("keyboard", "fn 被其他软件占用时，也可以按 ⌥⌘Space")
                feature("lock", "录音和历史只保存在这台 Mac")
            }.padding(.top, 20)
            Spacer()
            HStack {
                Text("历史保留").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("历史保留", selection: $retention) { Text("永久").tag(0); Text("30 天").tag(30); Text("7 天").tag(7); Text("1 天").tag(1) }.labelsHidden().frame(width: 100)
                Text("可稍后在历史页修改").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.bottom, 10)
            Toggle(isOn: $consent) {
                Text("我了解：听写时，录音和光标附近的少量文字会发送到你选择的模型服务商用于识别与整理。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.checkbox).padding(.bottom, 14)
            HStack(spacing: 8) {
                // Leaving without consent keeps onboarding pending; it returns on the next launch or recording.
                Button("稍后") { dismiss() }.buttonStyle(SoftCapsuleStyle())
                Button {
                    var next = model.config; next.onboardingDone = true; next.retentionDays = retention
                    model.saveConfig(next)
                    if model.config.onboardingDone { withAnimation(.easeOut(duration: 0.2)) { step = 2 } }
                } label: { Text("继续").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryCapsuleStyle(tint: .primary, foreground: Theme.canvas)).keyboardShortcut(.defaultAction).disabled(!consent || model.busy)
            }
        }
    }

    // One provider for both recognition and cleanup; Settings → 服务 can split them.
    var service: some View {
        let workspaceID = Provider.workspaceID(workspace)
        let ready = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!provider.isBailian || workspaceID != nil) && provider != .custom
        return VStack(alignment: .leading, spacing: 0) {
            Text("连接语音服务").font(.system(size: 32, weight: .heavy)).tracking(-0.5).padding(.bottom, 10)
            Text("Sayvia 用你自己的 API Key 直接请求服务商，Key 只保存在这台 Mac 的钥匙串里。").font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                Picker("服务商", selection: $provider) { ForEach(Provider.allCases) { Text(L($0.title)).tag($0) } }
                if provider.isBailian {
                    TextField("Workspace ID 或专属域名", text: $workspace).textFieldStyle(.roundedBorder)
                    Text("在百炼控制台的工作空间里找到。实时识别只在百炼上可用。").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if provider == .custom {
                    Text("自定义服务需要分别填写识别和整理的地址，请先继续，之后在 设置 → 服务 里填写。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    SecureField("API Key", text: $key).textFieldStyle(.roundedBorder)
                }
            }.padding(.top, 24)
            Spacer()
            HStack(spacing: 8) {
                Button("返回") { withAnimation(.easeOut(duration: 0.2)) { step = 1 } }.buttonStyle(SoftCapsuleStyle())
                Button { withAnimation(.easeOut(duration: 0.2)) { step = 3 }; refresh() } label: { Text("稍后设置") }.buttonStyle(SoftCapsuleStyle())
                Button {
                    var next = model.config
                    next.sttProvider = provider.rawValue; next.rewriteProvider = provider.rawValue
                    next.sttModel = provider.sttModel; next.rewriteModel = provider.rewriteModel
                    if provider.isBailian { next.bailianWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines) }
                    next.applyProviders()
                    let account = Keychain.account(endpoint: next.sttURL), secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.perform { try Keychain.write(secret, account: account) }
                    model.saveConfig(next); key = ""
                    withAnimation(.easeOut(duration: 0.2)) { step = 3 }; refresh()
                } label: { Text("继续").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryCapsuleStyle(tint: .primary, foreground: Theme.canvas)).keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }.onAppear { provider = model.config.recognitionProvider; workspace = model.config.bailianWorkspace ?? "" }
    }

    var permissions: some View {
        let ready = mic && trust && hotkeyActive
        return VStack(alignment: .leading, spacing: 0) {
            Text("开启三项权限").font(.system(size: 32, weight: .heavy)).tracking(-0.5).padding(.bottom, 10)
            Text("只需一次。Sayvia 只在你按下 fn 后读取当前输入框。").font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                permission("mic", "麦克风", "录下你说的话", mic) { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refresh() } }
                permission("character.cursor.ibeam", "辅助功能", "找到光标所在的输入框并写入", trust) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]; _ = AXIsProcessTrustedWithOptions(options as CFDictionary); refresh()
                }
                permission("keyboard", "全局按键", hotkeyActive ? "在任何应用里响应 fn" : (model.hotkeys.diagnostic.isEmpty ? "在任何应用里响应 fn" : model.hotkeys.diagnostic), hotkeyActive) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
            }.padding(.top, 24)
            Text("在系统设置中打开 Sayvia 的开关，回到这里后状态会自动更新。").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 10)
            Spacer()
            HStack(spacing: 8) {
                Button("返回") { withAnimation(.easeOut(duration: 0.2)) { step = 2 } }.buttonStyle(SoftCapsuleStyle())
                Button { withAnimation(.easeOut(duration: 0.2)) { step = 4 }; tryStarted = Date() } label: { Text(L(ready ? "继续" : "稍后再开，继续")).frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryCapsuleStyle(tint: ready ? .primary : .primary.opacity(0.5), foreground: Theme.canvas)).keyboardShortcut(.defaultAction)
            }
        }
    }

    var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("试着说一句").font(.system(size: 32, weight: .heavy)).tracking(-0.5).padding(.bottom, 10)
            Text("按一下 fn，读出下面这句话，再按一下 fn 结束。").font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("请读").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                Text("“嗯，明天下午三点，不对，四点开会，记得带上演示稿。”").font(.system(size: 16, weight: .medium)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).padding(.top, 20)
            let recording = model.phase == "recording"
            HStack(spacing: 12) {
                VStack(alignment: .leading) { Text("fn").font(.system(size: 15, weight: .semibold)); Spacer(); Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .padding(9).frame(width: 54, height: 54, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(recording ? Theme.accent : Theme.hairline, lineWidth: recording ? 1.5 : 1))
                    .shadow(color: recording ? Theme.accent.opacity(0.35) : .black.opacity(0.06), radius: recording ? 6 : 1, y: recording ? 0 : 1)
                    .scaleEffect(recording ? 0.96 : 1).animation(.spring(response: 0.25, dampingFraction: 0.6), value: recording)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(recording ? "正在听…" : model.busy ? model.message : "按 fn 开始")).font(.system(size: 13, weight: .bold))
                    Text(L(recording ? "再按 fn 结束" : "也可以点侧栏的「开始录音」")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.top, 20)
            Spacer()
            HStack(spacing: 8) {
                Button("跳过") { dismiss() }.buttonStyle(SoftCapsuleStyle())
                Button { dismiss() } label: { Text("开始使用").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryCapsuleStyle(tint: .primary, foreground: Theme.canvas)).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The right-hand stage shows the product doing the step's job.
    @ViewBuilder var demo: some View {
        switch step {
        case 1, 2:
            DemoNote {
                Text("嗯… 明天下午三点，不对，四点开会").font(.system(size: 13)).foregroundStyle(.tertiary).strikethrough()
                HStack(spacing: 0) { Text("明天下午四点开会").font(.system(size: 15, weight: .medium)); Rectangle().fill(Theme.accent).frame(width: 2, height: 18) }
            }
        case 3:
            VStack(alignment: .leading, spacing: 12) {
                Text("隐私与安全性 › 辅助功能").font(.system(size: 11)).foregroundStyle(.tertiary)
                HStack(spacing: 10) {
                    SayviaLogo(size: 22); Text("Sayvia").font(.system(size: 13, weight: .medium)); Spacer()
                    Toggle("", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(.green).allowsHitTesting(false)
                }.padding(.horizontal, 8).padding(.vertical, 6).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }.padding(16).frame(width: 320).card(radius: 14)
        default:
            VStack(spacing: 28) {
                let result = model.records.filter { $0.created >= tryStarted }.max { $0.created < $1.created }
                DemoNote {
                    if let result, !result.text.isEmpty {
                        Text("Sayvia 写出").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Text(result.text).font(.system(size: 15, weight: .medium)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 0) { Text("说完后，整理好的文字会出现在这里").font(.system(size: 14)).foregroundStyle(.tertiary); Rectangle().fill(Theme.accent).frame(width: 2, height: 18) }
                    }
                }
                if model.phase == "recording" { HUDSurface { HUDRecordingPill(level: model.volume, degraded: false, remaining: nil, cancel: { model.cancel() }, finish: { model.finish() }) }.environment(\.colorScheme, .dark) }
                else if model.busy { HUDSurface { HUDProcessingPill(text: model.message) }.environment(\.colorScheme, .dark) }
            }
        }
    }

    func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) { Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 18); Text(L(text)).font(.system(size: 13)) }
    }
    func permission(_ icon: String, _ title: String, _ detail: String, _ granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) { Text(L(title)).font(.system(size: 13, weight: .bold)); Text(L(detail)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            if granted { HStack(spacing: 5) { Circle().fill(.green).frame(width: 6, height: 6); Text("已开启").font(.system(size: 12)).foregroundStyle(.secondary) } }
            else { Button("去开启", action: action).buttonStyle(PrimaryCapsuleStyle(tint: .primary, foreground: Theme.canvas)).controlSize(.small) }
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(granted ? Theme.sidebar : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(granted ? .clear : Color.primary.opacity(0.6)))
    }
    func refresh() {
        if model.monitorSystem { model.hotkeys.start() }
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        trust = AXIsProcessTrusted(); hotkeyActive = model.hotkeys.active
    }
}

/// Mock note window used on the onboarding stage.
struct DemoNote<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 8, height: 8) }; Text("备忘录").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 4) }
            content
        }.padding(.horizontal, 18).padding(.vertical, 16).frame(width: 340, alignment: .leading).card(radius: 16).shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}
