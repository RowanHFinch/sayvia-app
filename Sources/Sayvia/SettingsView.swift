import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var config = Configuration()
    @State var section = "通用"
    @State private var learningConfirm = false
    @State private var resetConfirm = false
    @State private var trust = false
    @State private var canPost = false
    @State private var mic = false
    @State private var hotkeyActive = false
    @State private var hotkeyDiagnostic = ""
    @State private var editing: Preference?
    @State private var showsCorrections = false
    @State private var showsInputTest = false
    private let sections = [("通用", "gearshape"), ("服务", "key"), ("快捷键与权限", "keyboard"), ("个性化", "sparkles"), ("数据与隐私", "lock"), ("关于", "info.circle")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.0) { item, icon in
                    let selected = section == item
                    Button { section = item } label: {
                        HStack(spacing: 10) { Image(systemName: icon).frame(width: 18); Text(L(item)) }.font(.system(size: 14, weight: selected ? .medium : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 38)
                            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer()
            }.padding(.vertical, 24).padding(.horizontal, 12).frame(width: 210).background(Theme.sidebar)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L(section)).font(.system(size: 24, weight: .heavy)).tracking(-0.3)
                    Spacer()
                    Button { close() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("关闭").accessibilityLabel("关闭设置")
                }.padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 8)
                ScrollView { VStack(alignment: .leading, spacing: 26) {
                    switch section {
                    case "服务": ServiceSettings()
                    case "快捷键与权限": permissions
                    case "个性化": personalization
                    case "数据与隐私": privacy
                    case "关于": about
                    default: general
                    }
                }.padding(.horizontal, 40).padding(.top, 14).padding(.bottom, 32).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading) }
            }.background(Theme.canvas)
        }.tint(.primary)
        .onAppear { config = model.config; refreshPermissions() }
        // Permissions granted in System Settings show up when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .alert("启用自动学习？", isPresented: $learningConfirm) {
            Button("取消", role: .cancel) {}; Button("启用") { config.learning = true; saveField { $0.learning = true } }
        } message: { Text("在刚写入的文字里改正识别错的名字或术语后，改动处和前后几个词会发给你在“服务”里选择的整理模型判断，确认是误识别就加入词典，可撤销或删除。") }
        .alert("重置学习数据？", isPresented: $resetConfirm) {
            Button("取消", role: .cancel) {}; Button("重置", role: .destructive) { model.stopLearningObservation(); model.perform {
                try model.store?.resetLearning()
            } }
        } message: { Text("清空修改依据、自动偏好和自动学到的词，保留手动添加的内容与录音历史。") }
        .sheet(item: $editing) { preference in PreferenceEditor(preference: preference).environmentObject(model) }
    }
    var general: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(title: "识别", icon: "waveform") {
                SettingsRow("识别语言") {
                    Picker("识别语言", selection: $config.language) { Text("自动（中英混说）").tag(""); Text("中文").tag("zh"); Text("English").tag("en") }.labelsHidden().frame(width: 220)
                        .onChange(of: config.language) { _, value in saveField { $0.language = value } }
                }
            }
            SettingsGroup(title: "声音", icon: "speaker.wave.2") {
                SettingsRow("麦克风") {
                    Picker("麦克风", selection: $config.inputDeviceID) {
                        Text("系统默认麦克风").tag("")
                        ForEach(AudioCapture.devices, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                    }.labelsHidden().frame(width: 220).onChange(of: config.inputDeviceID) { _, value in saveField { $0.inputDeviceID = value } }
                }
                Divider()
                SettingsRow("提示音", detail: "开始和结束录音时播放") {
                    Toggle("", isOn: Binding(get: { model.config.interactionSounds ?? true }, set: { value in saveField { $0.interactionSounds = value } })).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
    var permissions: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(title: "快捷键", icon: "keyboard") {
                SettingsRow("用 fn 听写", detail: "按一下开始，再按一下结束。也可以按 ⌥⌘Space") {
                    ShortcutField(keys: ["fn"])
                    Toggle("", isOn: $config.useFn).labelsHidden().toggleStyle(.switch).onChange(of: config.useFn) { _, value in saveField { $0.useFn = value } }
                }
            }
            SettingsGroup(title: "权限", icon: "lock") {
                SettingsRow("麦克风", detail: "录音需要", status: mic) { if !mic { Button("开启") { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refreshPermissions() } }.buttonStyle(SoftCapsuleStyle()) } }
                Divider()
                SettingsRow("辅助功能", detail: "自动输入和 fn 快捷键需要", status: trust) { if !trust { Button("打开授权") { let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]; _ = AXIsProcessTrustedWithOptions(options as CFDictionary); refreshPermissions() }.buttonStyle(SoftCapsuleStyle()) } }
                // Lower-level checks only appear when they fail despite the main grant.
                if trust && !canPost { Divider(); SettingsRow("文字输入未生效", detail: "暂时只能保存结果；可重新打开辅助功能授权", status: false) { EmptyView() } }
                if trust && !hotkeyActive { Divider(); SettingsRow("快捷键未生效", detail: hotkeyDiagnostic.isEmpty ? "可重启 Sayvia 后再试" : hotkeyDiagnostic, status: false) { EmptyView() } }
            }
        }
    }
    var personalization: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(title: "自动学习", icon: "sparkle") {
                SettingsRow("自动学习", detail: "改正识别错的名字或术语后，自动加入词典") {
                    Toggle("", isOn: Binding(get: { model.config.learning }, set: { value in if value { learningConfirm = true } else { config.learning = false; saveField { $0.learning = false } } })).labelsHidden().toggleStyle(.switch)
                }
                if !model.corrections.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showsCorrections) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.corrections.reversed().enumerated()), id: \.element.id) { index, example in
                                if index > 0 { Divider() }
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text("\(example.before) → \(example.after)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                    Spacer(minLength: 12)
                                    Button("删除") { model.perform { try model.store?.deleteCorrection(example.id) } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.red)
                                }.padding(.vertical, 8)
                            }
                        }.padding(.top, 4)
                    } label: { Text("修改依据 · \(model.corrections.count) 条").font(.system(size: 13, weight: .semibold)) }.padding(.vertical, 11)
                }
            }
            SettingsGroup(title: "表达偏好", icon: "text.quote", accessory: AnyView(Button { editing = Preference(instruction: "") } label: { Label("新增", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.primary))) {
                if model.preferences.isEmpty { Text("还没有表达偏好").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 14) }
                ForEach(Array(model.preferences.enumerated()), id: \.element.id) { index, preference in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) { Text(preference.instruction).font(.system(size: 13)); Text("\(preference.origin == "manual" ? "手动" : "自动") · \(preference.scope.isEmpty ? "所有应用" : preference.scope)").font(.system(size: 12)).foregroundStyle(.secondary) }
                        Spacer(); Button("编辑") { editing = preference }.buttonStyle(SoftCapsuleStyle())
                        Toggle("", isOn: Binding(get: { preference.enabled }, set: { value in var next = preference; next.enabled = value; model.perform { try model.store?.save(next, kind: "preference", id: next.id) } })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }.padding(.vertical, 11)
                }
            }
            Button("重置学习数据…", role: .destructive) { resetConfirm = true }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.red)
        }
    }
    var privacy: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(title: "本机数据", icon: "internaldrive") {
                SettingsRow("占用空间", detail: "录音、历史和词典只保存在这台 Mac") {
                    Text(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                    Button("在 Finder 中显示") { if let url = model.store?.root { NSWorkspace.shared.open(url) } }.buttonStyle(SoftCapsuleStyle())
                }
                Divider()
                SettingsRow("历史保留期限") { Button("在历史页管理") { model.page = "历史记录"; close() }.buttonStyle(SoftCapsuleStyle()) }
            }
            SettingsGroup(title: "隐私", icon: "lock") {
                SettingsRow("参考屏幕文字", detail: "整理时把当前窗口里的可见文字一起发给整理模型，帮助认出人名和术语；密码框不读取") {
                    Toggle("", isOn: Binding(get: { model.config.screenContext != false }, set: { value in saveField { $0.screenContext = value } })).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                Text("只在你开始听写或重试时，把录音、词典和光标附近的少量文字发给你在“服务”里选择的服务商识别和整理；不做云同步，也不在后台上传。在本机删除不代表服务端同步删除。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
            }
        }
    }
    var storageBytes: Int64 {
        guard let root = model.store?.root, let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { sum, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { return sum }
            return sum + Int64(values.fileSize ?? 0)
        }
    }
    var about: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(title: "Sayvia", icon: "info.circle") {
                SettingsRow("版本", detail: [Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).map { "构建 \($0)" }].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "开发构建") { SayviaLogo(size: 28) }
                Divider()
                SettingsRow("使用帮助") { Button("打开") { model.page = "帮助"; close() }.buttonStyle(SoftCapsuleStyle()) }
                Divider()
                SettingsRow("问题报告", detail: "不含音频、文字或认证信息") { Button("导出") { model.feedback() }.buttonStyle(SoftCapsuleStyle()) }
            }
            // Troubleshooting for delivery problems; kept out of the everyday pages.
            SettingsGroup(title: "排查", icon: "wrench.and.screwdriver") {
                DisclosureGroup(isExpanded: $showsInputTest) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("点击后 8 秒内切到目标输入框。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 4)
                        SettingsRow("检查输入位置", detail: "只检查，不写入") { Button("开始") { model.testInput(inspectOnly: true) }.buttonStyle(SoftCapsuleStyle()).disabled(model.busy || !trust) }
                        Divider()
                        SettingsRow("测试自动输入", detail: "写入一句测试文字") { Button("开始") { model.testInput() }.buttonStyle(SoftCapsuleStyle()).disabled(model.busy || !trust) }
                        Divider()
                        SettingsRow("测试多行与 emoji", detail: "写入三行测试文字") { Button("开始") { model.testInput(text: "Sayvia 多行输入测试，保留光标附近的文字。\n第二行包含 emoji 🌍 和 English。\n第三行：测试完成。") }.buttonStyle(SoftCapsuleStyle()).disabled(model.busy || !trust) }
                        if !model.inputTestResult.isEmpty { Text(model.inputTestResult).font(.caption).textSelection(.enabled).padding(.top, 6) }
                        else if !model.lastPositionCheck.isEmpty { Text(model.lastPositionCheck).font(.caption).textSelection(.enabled).padding(.top, 6) }
                        if let evidence = model.inputTestEvidence { InputDeliveryDetails(evidence: evidence).padding(.top, 6) }
                    }.padding(.top, 6)
                } label: { Text("输入测试").font(.system(size: 13, weight: .semibold)) }.padding(.vertical, 11)
            }
        }
    }
    func close() { model.showSettings = false }
    func saveField(_ change: (inout Configuration) -> Void) { var next = model.config; change(&next); model.saveConfig(next) }
    func refreshPermissions() { if model.monitorSystem { model.hotkeys.start() }; trust = AXIsProcessTrusted(); canPost = CGPreflightPostEventAccess(); hotkeyActive = model.hotkeys.active; hotkeyDiagnostic = model.hotkeys.diagnostic; mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

}
struct PreferenceEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var preference: Preference
    var body: some View { VStack(alignment: .leading, spacing: 16) {
        Text("表达偏好").font(.title2.bold()); TextField("例如：精炼但礼貌", text: $preference.instruction); TextField("应用 Bundle ID，留空适用所有应用", text: $preference.scope)
        Toggle("启用", isOn: $preference.enabled)
        if !preference.evidenceIDs.isEmpty {
            Text("自动归纳依据").font(.headline)
            ForEach(model.corrections.filter { preference.evidenceIDs.contains($0.id) }) { example in Text("\(example.before) → \(example.after)").font(.caption).textSelection(.enabled) }
        }
        HStack { Button("删除", role: .destructive) { model.perform { try model.store?.remove(kind: "preference", id: preference.id) }; dismiss() }; Spacer(); Button("取消") { dismiss() }; Button("保存") { model.perform { try model.store?.save(preference, kind: "preference", id: preference.id) }; dismiss() }.disabled(preference.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.textFieldStyle(.roundedBorder).padding(28).frame(width: 470) }
}
struct HelpView: View {
    @EnvironmentObject var model: AppModel
    private let steps = [
        ("首次使用时确认隐私和历史保留设置。", "checkmark.shield"),
        ("授权麦克风；自动插入需要辅助功能。", "mic"),
        ("在目标输入框按 Fn 开始，说完再次按 Fn。", "keyboard"),
        ("识别与整理期间可以换框，文字准备好时以当前目标为准；写入开始后换框或键入会停止。", "arrow.left.arrow.right"),
        ("无法确认目标时，在历史中复制整理结果；可在权限页先检查输入位置。", "doc.on.doc"),
    ]
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        PageHeader(title: "使用帮助")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Divider().padding(.leading, 58) }
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26).background(Theme.accent.opacity(0.12), in: Circle()).foregroundStyle(Theme.accent)
                    Text(L(step.0)).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    Image(systemName: step.1).foregroundStyle(.secondary).padding(.top, 4)
                }.padding(.horizontal, 18).padding(.vertical, 14)
            }
        }.outlined(radius: 14)
        VStack(alignment: .leading, spacing: 10) {
            Text("安全输入框不采集上下文。无法可靠写入的控件只保存结果。历史重试始终只生成新版本，不自动插入；失败不会覆盖上一个成功版本。")
            Text("写入时会临时借用剪贴板粘贴一次，随后恢复原内容；剪贴板里有密码、图片等无法安全借用时，改为直接输入文字。整理暂不可用时会使用原文。Fn 冲突时可使用 ⌥⌘Space。")
        }.font(.system(size: 13)).foregroundStyle(.secondary).panel(padding: 18)
        HStack { Button("打开设置") { model.showSettings = true }; Button("导出不含内容的问题报告") { model.feedback() } }
    }.padding(.horizontal, 40).padding(.vertical, 36) } }
}

/// Borderless settings section: optional icon + gray title over a hairline,
/// rows flush with the content edge.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 7) { if let icon { Image(systemName: icon) }; Text(L(title)); Spacer(); accessory }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
        }
    }
}
extension String { var nonEmpty: String? { isEmpty ? nil : self } }

struct StatusDot: View {
    let ok: Bool, text: String
    var body: some View {
        HStack(spacing: 6) { Circle().fill(ok ? Color.green : Color.orange).frame(width: 6, height: 6); Text(L(text)).font(.system(size: 12)).foregroundStyle(.secondary) }.accessibilityElement(children: .combine)
    }
}

/// Read-only shortcut shown in a field box.
struct ShortcutField: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 5) { ForEach(keys, id: \.self) { KeyCap(key: $0) }; Spacer(minLength: 0) }
            .padding(.horizontal, 7).padding(.vertical, 5).frame(width: 190)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .accessibilityElement(children: .combine)
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var status: Bool?
    @ViewBuilder var control: Control
    init(_ title: String, detail: String? = nil, status: Bool? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.status = status; self.control = control()
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title)).font(.system(size: 13, weight: .semibold))
                if let detail { Text(L(detail)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
            Spacer(minLength: 16)
            if let status { StatusDot(ok: status, text: status ? "已允许" : "未生效") }
            control
        }.padding(.vertical, 11).frame(minHeight: 44)
    }
}

// Bring-your-own-key: provider, model and key for recognition and cleanup.
// Keys go to this Mac's Keychain, one per provider host.
struct ServiceSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var drafts: [String: String] = [:]
    @State private var saved: Set<String> = []
    @State private var status: (ok: Bool, text: String)?
    @State private var checking = false
    private var config: Configuration { model.config }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsGroup(title: "语音识别", icon: "waveform") {
                providerRows(config.recognitionProvider, select: { next in { $0.sttProvider = next.rawValue; $0.sttModel = next.sttModel; if next == .custom { $0.sttURL = "" } } },
                             url: \.sttURL, model: \.sttModel, hint: "https://…/v1/audio/transcriptions")
                if config.recognitionProvider.isBailian || ModelService.isBailianASR(config.sttURL) {
                    Divider()
                    SettingsRow("实时识别", detail: "边说边识别，说完更快出字") {
                        Toggle("", isOn: Binding(get: { config.realtimeCandidate != false }, set: { value in save { $0.realtimeCandidate = value } })).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            SettingsGroup(title: "文字整理", icon: "text.badge.checkmark") {
                providerRows(config.cleanupProvider, select: { next in { $0.rewriteProvider = next.rawValue; $0.rewriteModel = next.rewriteModel; if next == .custom { $0.rewriteURL = "" } } },
                             url: \.rewriteURL, model: \.rewriteModel, hint: "https://…/v1/chat/completions")
            }
            if config.recognitionProvider.isBailian || config.cleanupProvider.isBailian {
                SettingsGroup(title: "阿里云百炼", icon: "building.2") {
                    SettingsRow("Workspace ID", detail: Provider.workspaceID(config.bailianWorkspace ?? "") == nil ? "在百炼控制台的工作空间里找到，也可以直接粘贴专属域名" : "已使用该工作空间的专属域名") {
                        TextField("ws-…", text: Binding(get: { config.bailianWorkspace ?? "" }, set: { value in save { $0.bailianWorkspace = value } }))
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }
            }
            SettingsGroup(title: "API Key", icon: "key") {
                ForEach(Array(hosts.enumerated()), id: \.element) { index, host in
                    if index > 0 { Divider() }
                    SettingsRow(host, detail: saved.contains(host) ? "已保存在钥匙串" : "未设置") {
                        SecureField(saved.contains(host) ? "输入新 Key 以替换" : "粘贴 API Key", text: Binding(get: { drafts[host] ?? "" }, set: { drafts[host] = $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                        Button("保存") { saveKey(host) }.buttonStyle(SoftCapsuleStyle()).disabled((drafts[host] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if hosts.isEmpty { Text("先选择服务商并填写地址或 Workspace ID").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 12) }
                Divider()
                SettingsRow("检查连接", detail: status?.text ?? "向整理模型发一个极短请求，会产生极少量费用") {
                    if let status { StatusDot(ok: status.ok, text: status.ok ? "可用" : "失败") }
                    Button("检查") { check() }.buttonStyle(SoftCapsuleStyle()).disabled(checking || model.busy || hosts.isEmpty)
                }
            }
        }.onAppear(perform: refresh).onChange(of: hosts) { _, _ in refresh() }
    }
    private var hosts: [String] {
        var result: [String] = []
        for address in [config.sttURL, config.rewriteURL] {
            if let host = URL(string: address)?.host?.lowercased(), !result.contains(host) { result.append(host) }
        }
        return result
    }
    @ViewBuilder private func providerRows(_ provider: Provider, select: @escaping (Provider) -> (inout Configuration) -> Void,
                                           url: WritableKeyPath<Configuration, String>, model field: WritableKeyPath<Configuration, String>, hint: String) -> some View {
        SettingsRow("服务商") {
            Picker("服务商", selection: Binding(get: { provider }, set: { next in save(select(next)) })) {
                ForEach(Provider.allCases) { Text(L($0.title)).tag($0) }
            }.labelsHidden().frame(width: 220)
        }
        if provider == .custom {
            Divider()
            SettingsRow("地址", detail: "OpenAI 兼容的完整 HTTPS 端点") {
                TextField(hint, text: binding(url)).textFieldStyle(.roundedBorder).frame(width: 300)
            }
        }
        Divider()
        SettingsRow("模型") { TextField("模型名称", text: binding(field)).textFieldStyle(.roundedBorder).frame(width: 220) }
    }
    private func binding(_ path: WritableKeyPath<Configuration, String>) -> Binding<String> {
        Binding(get: { config[keyPath: path] }, set: { value in save { $0[keyPath: path] = value.trimmingCharacters(in: .whitespacesAndNewlines) } })
    }
    private func save(_ change: (inout Configuration) -> Void) {
        var next = config; change(&next); next.applyProviders()
        model.saveConfig(next); status = nil
    }
    private func refresh() { saved = Set(hosts.filter { (try? Keychain.exists(Keychain.account(endpoint: "https://" + $0))) == true }) }
    private func saveKey(_ host: String) {
        let key = (drafts[host] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        model.perform { try Keychain.write(key, account: Keychain.account(endpoint: "https://" + host)) }
        drafts[host] = nil; status = nil; refresh()
    }
    // A one-token cleanup request proves the cleanup endpoint, model and key. Recognition
    // shares that proof only when it uses the same host; otherwise the first dictation tests it.
    private func check() {
        checking = true
        Task {
            defer { checking = false }
            do {
                let service = try ModelService.direct(configuration: config)
                try service.validate(needsAudio: true)
                var body: [String: Any] = ["model": config.rewriteModel, "messages": [["role": "user", "content": "ok"]], "max_tokens": 1, "stream": false]
                if config.rewriteModel.hasPrefix("qwen3") { body["enable_thinking"] = false }
                _ = try await service.send(url: config.rewriteURL, key: service.rewriteKey, data: JSONSerialization.data(withJSONObject: body), contentType: "application/json", timeout: 15)
                status = (true, hosts.count > 1 ? "整理可用；识别会在第一次听写时验证" : "识别和整理使用同一个 Key，整理已验证可用")
            } catch { status = (false, (error as? AppError)?.message ?? error.localizedDescription) }
        }
    }
}
