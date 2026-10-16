import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers

extension Color {
    /// Hex colors that follow the system appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

// Visual language: white window with an inset
// gray sidebar, a dotted gray "stage" holding white cards, heavy titles, and ember as the
// only brand color.
enum Theme {
    static let canvas = Color(light: 0xFFFFFF, dark: 0x1E1E20)
    static let sidebar = Color(light: 0xF6F6F7, dark: 0x29292B)
    static let stage = Color(light: 0xF3F3F4, dark: 0x252527)
    static let card = Color(light: 0xFFFFFF, dark: 0x303033)
    static let selection = Color.primary.opacity(0.08)
    static let panel = sidebar
    static let hairline = Color.primary.opacity(0.08)
    static let accent = Color(red: 0.941, green: 0.353, blue: 0.157)
    static let learned = accent
}

extension View {
    func panel(padding: CGFloat = 20, radius: CGFloat = 16) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
    func outlined(radius: CGFloat = 14) -> some View {
        self.background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.hairline))
    }
    /// Borderless white card that floats on the stage.
    func card(radius: CGFloat = 16) -> some View {
        self.background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.primary.opacity(0.04)))
            .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
    }
    /// Staggered entrance used when a page opens. With Reduce Motion it only fades;
    /// movement is what that setting removes, not every change.
    func entrance(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self.opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? .easeOut(duration: 0.25).delay(delay) : .spring(response: 0.45, dampingFraction: 0.8).delay(delay), value: shown)
    }
}

struct PageTitle: View {
    let title: String
    var body: some View { Text(L(title)).font(.system(size: 34, weight: .heavy)).tracking(-0.5).accessibilityAddTraits(.isHeader) }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) { PageTitle(title: title); Spacer(); trailing }.padding(.bottom, 2)
    }
}
extension PageHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var symbols: [Value: (String, Color)] = [:]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let selected = selection == value
                Button { selection = value } label: {
                    HStack(spacing: 5) {
                        if let symbol = symbols[value] { Image(systemName: symbol.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(symbol.1) }
                        Text(L(title))
                    }.font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(selected ? Theme.card : .clear, in: Capsule())
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(3).background(Color.primary.opacity(0.055), in: Capsule())
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
        }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 7).frame(width: 220)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }
}

struct KeyCap: View {
    let key: String
    var body: some View {
        Text(key).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.05), radius: 0, y: 1)
    }
}
struct Shortcut: View {
    let keys: [String]
    var body: some View { HStack(spacing: 5) { ForEach(keys, id: \.self) { KeyCap(key: $0) } }.accessibilityElement(children: .combine) }
}

struct PrimaryCapsuleStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var foreground: Color = .white
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label.font(.system(size: 13, weight: .bold)).foregroundStyle(foreground)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
struct SoftCapsuleStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.055), in: Capsule())
    }
}

/// Faint dot grid behind the home insight cards. A pre-drawn 12pt tile is repeated by the
/// renderer, so resizing the window does not redraw thousands of dots per frame.
struct DotGrid: View {
    @Environment(\.colorScheme) private var scheme
    private static func tile(white: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            (white ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.09)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.3, y: 5.3, width: 1.4, height: 1.4)).fill(); return true
        }
        return image
    }
    private static let light = tile(white: false), dark = tile(white: true)
    var body: some View {
        Rectangle().fill(ImagePaint(image: Image(nsImage: scheme == .dark ? Self.dark : Self.light))).accessibilityHidden(true)
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onboarding = false
    @State private var opened = false
    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 214)
            ZStack {
                Group {
                    switch model.page {
                    case "历史记录": HistoryView()
                    case "词典": DictionaryView()
                    case "帮助": HelpView()
                    default: HomeView()
                    }
                }
                // Page switch: fade in while rising 6pt (motion.page).
                .id(model.page).transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }.padding(.leading, 30).padding(.trailing, 22).padding(.top, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(.easeOut(duration: 0.18), value: model.page)
        }
        .padding(8)
        // Window open: settle from 97% with a soft spring.
        .opacity(opened ? 1 : 0).scaleEffect(opened || reduceMotion ? 1 : 0.97)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.82), value: opened)
        .task { HomeView.introPlayed = false; try? await Task.sleep(for: .milliseconds(30)); opened = true }
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 960, minHeight: 640)
        .tint(.primary)
        // Settings float over the dimmed window rather than sliding down as a sheet.
        .overlay {
            if model.showSettings {
                ZStack {
                    Color.black.opacity(0.28).contentShape(Rectangle()).onTapGesture { model.showSettings = false }.accessibilityHidden(true)
                    // Scales with the main window: ~84% of it, between 760×560 and 1090×790.
                    GeometryReader { proxy in
                        SettingsView().environmentObject(model)
                            .frame(width: min(1090, max(760, proxy.size.width * 0.84)), height: min(790, max(560, proxy.size.height * 0.86)))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.08)))
                            .shadow(color: .black.opacity(0.25), radius: 30, y: 16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }.ignoresSafeArea()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.showSettings)
        .sheet(isPresented: $onboarding) { OnboardingView().environmentObject(model) }
        .alert("需要处理", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .onAppear { if !model.config.onboardingDone { onboarding = true } }
        // Recording before consent asks for setup; route that to onboarding instead of settings.
        .onChange(of: model.showSettings) { _, shown in if shown, !model.config.onboardingDone { model.showSettings = false; onboarding = true } }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var selectionSpace
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                SayviaLogo(size: 22)
                Text("Sayvia").font(.system(size: 16, weight: .bold)).tracking(-0.3)
                Text("Beta").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            }.padding(.horizontal, 8).padding(.top, 44).padding(.bottom, 16).accessibilityElement(children: .combine)
            ForEach([("首页", "house"), ("历史记录", "clock.arrow.circlepath"), ("词典", "book.closed")], id: \.0) { title, icon in
                let selected = model.page == title
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.page = title } } label: {
                    HStack(spacing: 10) { Image(systemName: icon).font(.system(size: 14)).frame(width: 20); Text(L(title)) }
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 36)
                        .background {
                            // The selection pill slides between items (motion.morph).
                            if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.selection).matchedGeometryEffect(id: "selection", in: selectionSpace) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
            DictationCard()
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 6)
            HStack(spacing: 14) {
                Button { model.feedback() } label: { Image(systemName: "envelope") }.help("导出问题报告（不含音频与文字）").accessibilityLabel("导出问题报告")
                Spacer()
                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.help("设置").accessibilityLabel("设置")
                Button { model.page = "帮助" } label: { Image(systemName: "questionmark.circle") }.help("帮助").accessibilityLabel("帮助")
            }.font(.system(size: 15)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 4)
        }.padding(10).frame(maxHeight: .infinity)
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Sidebar control for the current dictation session; mirrors the menu bar actions.
struct DictationCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let recording = model.phase == "recording"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(recording ? Theme.accent : model.busy ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(L(model.message)).font(.system(size: 13, weight: .medium)).lineLimit(2)
            }
            Button { model.toggle() } label: {
                Label(L(recording ? "结束录音" : "开始录音"), systemImage: recording ? "stop.fill" : "mic.fill").frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryCapsuleStyle(tint: recording ? .primary : Theme.accent, foreground: recording ? Theme.canvas : .white))
                .disabled(model.busy && !recording)
            if model.busy { Button("取消") { model.cancel() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).card(radius: 14)
    }
}

/// Usage numbers derived only from locally retained recordings.
struct UsageStats {
    var characters = 0, recordings = 0, seconds: Double = 0
    var counts: [Date: Int] = [:]
    var activeDays: Int { counts.count }
    var charsPerMinute: Int? { seconds >= 1 ? Int((Double(characters) / (seconds / 60)).rounded()) : nil }
    init(_ records: [Recording]) {
        let calendar = Calendar.current
        for record in records where !record.deleting {
            characters += record.text.count; recordings += 1; seconds += record.duration
            counts[calendar.startOfDay(for: record.created), default: 0] += 1
        }
    }
    /// Consecutive active days ending today, or yesterday when today has no recording yet.
    func currentStreak(now: Date = Date(), calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: now)
        if counts[day] == nil { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while counts[day] != nil { streak += 1; day = calendar.date(byAdding: .day, value: -1, to: day)! }
        return streak
    }
    func longestStreak(calendar: Calendar = .current) -> Int {
        var best = 0, run = 0, previous: Date?
        for day in counts.keys.sorted() {
            run = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day ? run + 1 : 1
            best = max(best, run); previous = day
        }
        return best
    }
}

/// Text that counts from 0 to its value when the value animates in.
/// SwiftUI interpolates `animatableData` per frame only on modifiers and shapes, not plain views.
struct CountUpText: View {
    let value: Double
    let format: (Double) -> String
    var body: some View { Color.clear.frame(width: 0, height: 0).modifier(CountUpModifier(value: value, format: format)) }
}
private struct CountUpModifier: ViewModifier, Animatable {
    var value: Double
    let format: (Double) -> String
    var animatableData: Double { get { value } set { value = newValue } }
    func body(content: Content) -> some View { Text(format(value)).monospacedDigit() }
}

struct HomeView: View {
    /// Reset by MainView each time the window opens.
    @MainActor static var introPlayed = false
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var range = 0
    var body: some View {
        let all = UsageStats(model.records)
        let since = range == 0 ? Date.distantPast : Calendar.current.date(byAdding: .day, value: -range, to: Calendar.current.startOfDay(for: Date()))!
        let stats = range == 0 ? all : UsageStats(model.records.filter { $0.created >= since })
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "说出来，不必打字")
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("洞察").font(.system(size: 17, weight: .bold)).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Picker("范围", selection: $range) { Text("全部时间").tag(0); Text("近 30 天").tag(30); Text("近 7 天").tag(7) }.pickerStyle(.inline).labelsHidden()
                            } label: {
                                HStack(spacing: 4) { Text(range == 0 ? "全部时间" : "近 \(range) 天"); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                                    .padding(.horizontal, 12).padding(.vertical, 5).background(Theme.card, in: Capsule())
                            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("统计只来自本机保留的记录")
                        }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
                        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                            GridRow {
                                metric(Double(stats.characters), compact, "字", "口述字数", 0)
                                let time = duration(stats.seconds)
                                metric(time.0, { time.2($0) }, time.1, "总口述时长", 1)
                            }
                            GridRow {
                                if let cpm = stats.charsPerMinute { metric(Double(cpm), { "\(Int($0.rounded()))" }, "字/分钟", "平均口述速度", 2) }
                                else { metric(0, { _ in "—" }, "字/分钟", "平均口述速度", 2) }
                                metric(Double(stats.recordings), { "\(Int($0.rounded()))" }, "条", "已保存录音", 3)
                            }
                        }
                        ActivityPanel(stats: all, shown: shown).equatable().entrance(shown, delay: 0.26, reduceMotion: reduceMotion)
                        DictionarySnapshot().entrance(shown, delay: 0.32, reduceMotion: reduceMotion)
                    }.padding(12)
                }
                .background { ZStack { Theme.stage; DotGrid() } }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    ShortcutPanel().entrance(shown, delay: 0.2, reduceMotion: reduceMotion)
                    GlowCard(tint: Theme.accent) {
                        Image(systemName: "lock").font(.system(size: 14, weight: .medium))
                        Text("历史只在本机").font(.system(size: 14, weight: .bold))
                        Text("录音和结果保存在这台 Mac，识别和整理时才发送到你选择的模型服务商。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("设置与权限") { model.showSettings = true }.buttonStyle(.link).font(.system(size: 12))
                    }.entrance(shown, delay: 0.27, reduceMotion: reduceMotion)
                    GlowCard(tint: Color(red: 0.36, green: 0.5, blue: 0.85)) {
                        Text("小技巧").font(.system(size: 14, weight: .bold))
                        Text("说错了直接改口：「三点，不对，四点」会写成「四点」。").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.entrance(shown, delay: 0.34, reduceMotion: reduceMotion)
                    Spacer()
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("版本 \(version)").font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.frame(width: 196).padding(.bottom, 14)
            }
        }
        // The entrance plays once per window opening; returning to 首页 shows the final state at once.
        // It starts after the first frame so the zero state is drawn and the animation actually runs.
        .task {
            if Self.introPlayed { var instant = Transaction(); instant.disablesAnimations = true; withTransaction(instant) { shown = true }; return }
            try? await Task.sleep(for: .milliseconds(60)); shown = true; Self.introPlayed = true
        }
    }
    func metric(_ value: Double, _ format: @escaping (Double) -> String, _ unit: String, _ title: String, _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                CountUpText(value: shown ? value : 0, format: format).font(.system(size: 24, weight: .bold)).tracking(-0.5)
                    .animation(.easeOut(duration: 0.9).delay(0.1 + Double(index) * 0.05), value: shown)
                Text(L(unit)).font(.system(size: 12, weight: .bold))
            }
            Text(L(title)).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).card()
            .entrance(shown, delay: 0.06 * Double(index), reduceMotion: reduceMotion)
            .accessibilityElement(children: .combine)
    }
    func compact(_ value: Double) -> String { value >= 10_000 ? String(format: "%.1f万", value / 10_000) : Int(value.rounded()).formatted() }
    /// Display value, unit and formatter for a duration in seconds.
    func duration(_ seconds: Double) -> (Double, String, (Double) -> String) {
        if seconds >= 3600 { return (seconds / 3600, "小时", { String(format: "%.1f", $0) }) }
        if seconds >= 60 { return ((seconds / 60).rounded(.down), "分钟", { "\(Int($0.rounded()))" }) }
        return (seconds.rounded(.down), "秒", { "\(Int($0.rounded()))" })
    }
}

/// Right-rail card with a soft color glow standing in for imagery.
struct GlowCard<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .bottomTrailing) {
                    Theme.sidebar
                    LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [tint.opacity(0.24), tint.opacity(0)], center: .bottomTrailing, startRadius: 0, endRadius: 150)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct DictionarySnapshot: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let enabled = model.dictionary.filter(\.enabled)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                HStack(alignment: .firstTextBaseline, spacing: 3) { Text("\(enabled.count)").font(.system(size: 20, weight: .bold)); Text("个词语").font(.system(size: 12, weight: .bold)) }
                Spacer()
                Button("查看词典") { model.page = "词典" }.buttonStyle(SoftCapsuleStyle())
            }
            if enabled.isEmpty {
                Text("改正写错的人名和术语后，它们会出现在这里。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(enabled.prefix(6)) { entry in
                        HStack(spacing: 4) {
                            if entry.origin == "automatic" { Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent) }
                            Text(entry.term).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }.padding(.horizontal, 10).padding(.vertical, 4).background(Color.primary.opacity(0.045), in: Capsule())
                    }
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct ActivityPanel: View, Equatable {
    let stats: UsageStats
    var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pages back in time; 0 ends with the current week.
    @State private var page = 0
    @State private var hovered: (Date, Int)?
    private let cell: CGFloat = 12, gap: CGFloat = 4, labelWidth: CGFloat = 16
    static func == (a: ActivityPanel, b: ActivityPanel) -> Bool { a.shown == b.shown && a.stats.counts == b.stats.counts }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                figure("\(stats.activeDays)", "活跃天数"); figure("\(stats.currentStreak())", "当前连续"); figure("\(stats.longestStreak())", "最长连续")
            }
            GeometryReader { proxy in
                let weeks = max(1, Int((proxy.size.width - labelWidth - 14 + gap) / (cell + gap)))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: gap) {
                        VStack(spacing: gap) { ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: labelWidth - gap, height: cell, alignment: .leading) } }
                        // One canvas draws every cell; the reveal sweeps left to right as `progress` animates.
                        Color.clear.frame(width: CGFloat(weeks) * (cell + gap) - gap, height: 7 * cell + 6 * gap)
                            .modifier(HeatmapCells(progress: shown ? 1 : 0, weeks: weeks, page: page, counts: stats.counts, first: stats.counts.keys.min(), cell: cell, gap: gap, grow: !reduceMotion))
                            .animation((reduceMotion ? Animation.easeOut(duration: 0.6) : .easeOut(duration: 1.0)).delay(0.3), value: shown)
                            .onContinuousHover { phase in
                                if case .active(let point) = phase {
                                    let column = Int(point.x / (cell + gap)), row = Int(point.y / (cell + gap))
                                    let (day, offset) = Self.date(weeks: weeks, column: column, row: row, page: page)
                                    hovered = column < weeks && row < 7 && offset >= 0 ? (day, stats.counts[day] ?? 0) : nil
                                } else { hovered = nil }
                            }
                    }
                    HStack(spacing: gap) {
                        Button { withAnimation(.easeOut(duration: 0.2)) { page += 1 } } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).frame(width: labelWidth - gap, alignment: .leading)
                            .disabled(!canGoBack(weeks: weeks)).help("更早").accessibilityLabel("查看更早的活跃记录")
                        ForEach(0..<weeks, id: \.self) { column in
                            Text(monthLabel(weeks: weeks, column: column)).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize().frame(width: cell, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        Button { withAnimation(.easeOut(duration: 0.2)) { page -= 1 } } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .disabled(page == 0).opacity(page == 0 ? 0.35 : 1).help("更近").accessibilityLabel("查看更近的活跃记录")
                    }
                }
            }.frame(height: 7 * cell + 6 * gap + 20).accessibilityHidden(true)
            HStack(spacing: 4) {
                if let hovered {
                    Text("\(hovered.0.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.abbreviated)))：\(hovered.1) 条").foregroundStyle(.secondary)
                } else {
                    Text("更少"); ForEach([1, 2, 4, 7], id: \.self) { RoundedRectangle(cornerRadius: 2.5).fill(HeatmapCells.shade($0)).frame(width: 10, height: 10) }; Text("更多")
                }
            }.font(.system(size: 11)).foregroundStyle(.tertiary).frame(height: 14).accessibilityHidden(true)
        }.padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).card()
            .accessibilityElement(children: .contain).accessibilityLabel("活跃 \(stats.activeDays) 天，当前连续 \(stats.currentStreak()) 天")
    }
    func figure(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) { Text(value).font(.system(size: 20, weight: .bold)); Text("天").font(.system(size: 12, weight: .bold)) }
            Text(L(title)).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    static func date(weeks: Int, column: Int, row: Int, page: Int) -> (Date, Int) {
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        let offset = (weeks - 1 - column + page * weeks) * 7 + (weekday - row)
        return (calendar.date(byAdding: .day, value: -offset, to: today)!, offset)
    }
    func canGoBack(weeks: Int) -> Bool {
        guard let first = stats.counts.keys.min() else { return false }
        return Self.date(weeks: weeks, column: 0, row: 0, page: page).0 > first
    }
    func monthLabel(weeks: Int, column: Int) -> String {
        let first = Self.date(weeks: weeks, column: column, row: 0, page: page).0
        let previous = column > 0 ? Self.date(weeks: weeks, column: column - 1, row: 0, page: page).0 : nil
        let calendar = Calendar.current
        guard previous.map({ calendar.component(.month, from: $0) != calendar.component(.month, from: first) }) ?? false else { return "" }
        return Self.monthFormatter.string(from: first)
    }
    // Labels follow the app's UI language, not the region format.
    static let weekdays: [String] = { var calendar = Calendar(identifier: .gregorian); calendar.locale = uiLocale; return calendar.veryShortWeekdaySymbols }()
    static let monthFormatter: DateFormatter = { let formatter = DateFormatter(); formatter.locale = uiLocale; formatter.setLocalizedDateFormatFromTemplate("MMM"); return formatter }()
}

/// Draws the whole heatmap in one pass. Days before the first retained recording are hatched,
/// future days of this week are outlined, and `progress` reveals columns from left to right.
private struct HeatmapCells: ViewModifier, Animatable {
    var progress: Double
    let weeks: Int, page: Int
    let counts: [Date: Int], first: Date?
    let cell: CGFloat, gap: CGFloat, grow: Bool
    var animatableData: Double { get { progress } set { progress = newValue } }
    static func shade(_ count: Int) -> Color {
        switch count { case 0: Color.primary.opacity(0.05); case 1: Theme.accent.opacity(0.2); case 2...3: Theme.accent.opacity(0.45); case 4...6: Theme.accent.opacity(0.72); default: Theme.accent }
    }
    func body(content: Content) -> some View {
        content.overlay {
            Canvas { context, _ in
                let span = Double(weeks) + 6
                for column in 0..<weeks {
                    let reveal = min(1, max(0, progress * span - Double(column)))
                    guard reveal > 0 else { continue }
                    let size = cell * (grow ? 0.6 + 0.4 * reveal : 1), inset = (cell - size) / 2
                    for row in 0..<7 {
                        let (day, offset) = ActivityPanel.date(weeks: weeks, column: column, row: row, page: page)
                        let rect = CGRect(x: CGFloat(column) * (cell + gap) + inset, y: CGFloat(row) * (cell + gap) + inset, width: size, height: size)
                        let shape = Path(roundedRect: rect, cornerRadius: 3.5 * size / cell, style: .continuous)
                        var layer = context; layer.opacity = reveal
                        if offset < 0 { layer.stroke(shape, with: .color(Theme.hairline), lineWidth: 1) }
                        else if first.map({ day < $0 }) ?? true {
                            layer.fill(shape, with: .color(.primary.opacity(0.035)))
                            var lines = Path()
                            for x in stride(from: rect.minX - rect.height, to: rect.maxX, by: 4) { lines.move(to: CGPoint(x: x, y: rect.maxY)); lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY)) }
                            layer.clip(to: shape); layer.stroke(lines, with: .color(.primary.opacity(0.07)), lineWidth: 1)
                        } else { layer.fill(shape, with: .color(Self.shade(counts[day] ?? 0))) }
                    }
                }
            }
        }
    }
}

struct ShortcutPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            item("听写", model.config.useFn ? ["fn"] : ["⌥", "⌘", "space"])
            item("备用", ["⌥", "⌘", "space"])
            if !model.config.useFn { Text("fn 快捷键已在设置中关闭").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    func item(_ title: String, _ keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(L(title)).font(.system(size: 12)).foregroundStyle(.secondary); Shortcut(keys: keys) }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter = "全部"
    @State private var days = 0
    @State private var retentionConfirm = false
    @State private var customDays = false
    @State private var deleteRecord: Recording?
    @State private var detail: Recording?
    @State private var hovered: String?
    @State private var expanded: String?
    /// Records the user should look at: not confirmed in the target, failed or cancelled.
    static func needsAttention(_ record: Recording) -> Bool {
        ["failed", "cancelled"].contains(record.latestStatus) || !["inserted", "unchanged", "input_dispatched", "input_text_present"].contains(record.insertion)
    }
    var filtered: [Recording] { model.records.filter { record in
        (query.isEmpty || record.attempts.contains { $0.raw.localizedCaseInsensitiveContains(query) || $0.result.localizedCaseInsensitiveContains(query) })
            && (filter == "全部" || (filter == "需处理") == Self.needsAttention(record))
    } }
    var body: some View {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.created) }.sorted { $0.key > $1.key }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                PageHeader(title: "历史记录") {
                    SearchField(prompt: "搜索原文与整理结果", text: $query)
                    Menu {
                        Button("在访达中显示本机数据") { if let url = model.store?.root { NSWorkspace.shared.open(url) } }
                        Button("导出问题报告") { model.feedback() }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("历史更多操作")
                }.padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("保存历史", systemImage: "internaldrive").font(.system(size: 13, weight: .bold))
                            Text("选择在这台 Mac 上保留文字和录音的时间，从录音时间开始计算。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Choosing a period asks for confirmation before anything is cleaned up;
                        // "自定义…" reveals a day field (0 = 永久, at most 36500).
                        Picker("保留期限", selection: Binding(get: { customDays ? -1 : days }, set: { value in
                            if value == -1 { customDays = true; return }
                            customDays = false; days = value; if value != model.config.retentionDays { retentionConfirm = true }
                        })) {
                            Text("永久").tag(0); Text("1 年").tag(365); Text("30 天").tag(30); Text("7 天").tag(7); Text("1 天").tag(1)
                            if ![0,1,7,30,365].contains(days) { Text("\(days) 天").tag(days) }
                            Divider(); Text("自定义…").tag(-1)
                        }.labelsHidden().frame(width: 110).disabled(model.busy)
                        if customDays {
                            TextField("天数", value: $days, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                            Button("应用") { if days < 0 || days > 36500 { model.error = "请输入 0–36500 天。" } else { retentionConfirm = true; customDays = false } }
                                .buttonStyle(SoftCapsuleStyle()).disabled(model.busy || days == model.config.retentionDays)
                        }
                    }.padding(.vertical, 12)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Label("历史只保存在本机", systemImage: "lock").font(.system(size: 13, weight: .bold))
                        Text("录音和结果保存在这台 Mac；识别和整理时，音频与文字会发送到你选择的模型服务商。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }.padding(.horizontal, 16).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                PillPicker(selection: $filter, options: ["全部", "已写入", "需处理"].map { ($0, $0) }).padding(.vertical, 8)
                if groups.isEmpty { ContentUnavailableView("还没有相关记录", systemImage: "waveform", description: Text("按 fn 开始录音；失败和取消的记录也会保留。")).padding(.top, 30) }
                ForEach(groups, id: \.key) { day, records in
                    Text(dayTitle(day)).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8).padding(.horizontal, 2)
                    ForEach(records) { record in
                        if expanded == record.id { expandedRow(record) } else { row(record) }
                    }
                }
            }.padding(.trailing, 8).padding(.bottom, 24)
        }
        .onAppear { days = model.config.retentionDays }
        .alert("更改保留期限", isPresented: $retentionConfirm) { Button("取消", role: .cancel) { days = model.config.retentionDays }; Button("确认并应用", role: .destructive) { var next = model.config; next.retentionDays = days; model.saveConfig(next); model.maintain() } } message: { Text("将清理 \(model.records.filter { Safety.expired($0, days: days) }.count) 条到期记录及对应音频和学习依据。期限从原始录音时间计算。0 天表示永久。") }
        .alert("删除录音？", isPresented: Binding(get: { deleteRecord != nil }, set: { if !$0 { deleteRecord = nil } })) { Button("取消", role: .cancel) { deleteRecord = nil }; Button("删除", role: .destructive) { if let record = deleteRecord { model.delete(record) }; deleteRecord = nil } } message: { Text("将删除所有处理版本、本地音频和关联学习依据。无法撤销。") }
        .sheet(item: $detail) { record in RecordDetail(recordID: record.id).environmentObject(model) }
    }
    func row(_ record: Recording) -> some View {
        let active = hovered == record.id
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            time(record)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.text.isEmpty ? status(record.latestStatus) : record.text).font(.system(size: 13)).lineSpacing(3).lineLimit(3)
                    .foregroundStyle(record.text.isEmpty ? .secondary : .primary).frame(maxWidth: .infinity, alignment: .leading)
                meta(record)
            }
            HStack(spacing: 10) {
                Button { model.copy(record.text) } label: { Image(systemName: "doc.on.doc") }.help("复制").accessibilityLabel("复制结果").disabled(record.text.isEmpty)
                Button { model.retry(record, kind: "rewrite") } label: { Image(systemName: "wand.and.stars") }.help("重新整理（新增版本，不写入当前应用）").accessibilityLabel("重新整理").disabled(model.busy || record.displayed?.raw.isEmpty != false)
                Menu { actions(record) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("录音更多操作")
            }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary).opacity(active ? 1 : 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(active ? Theme.sidebar : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(active ? .clear : Theme.hairline))
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = record.id } else if hovered == record.id { hovered = nil } }
        .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded = record.id } }
        .contextMenu { Button("复制") { model.copy(record.text) }.disabled(record.text.isEmpty); actions(record) }
    }
    func expandedRow(_ record: Recording) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            time(record)
            VStack(alignment: .leading, spacing: 10) {
                Text(record.text.isEmpty ? status(record.latestStatus) : record.text).font(.system(size: 14, weight: .medium)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let raw = record.displayed?.raw ?? ""
                if hasAudio(record) || (!raw.isEmpty && raw != record.text) {
                    VStack(alignment: .leading, spacing: 8) {
                        if hasAudio(record), let url = model.store?.audioURL(record) { AudioStrip(url: url, duration: record.duration) }
                        if !raw.isEmpty, raw != record.text {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("原文").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                                Text(raw).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 8) {
                    Button { model.copy(record.text) } label: { Label("复制", systemImage: "doc.on.doc") }.buttonStyle(PrimaryCapsuleStyle(tint: .primary, foreground: Theme.canvas)).controlSize(.small).disabled(record.text.isEmpty)
                    Button { model.retry(record, kind: "rewrite") } label: { Label("重新整理", systemImage: "wand.and.stars") }.buttonStyle(SoftCapsuleStyle()).disabled(model.busy || record.displayed?.raw.isEmpty != false)
                    Menu { actions(record) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).accessibilityLabel("录音更多操作")
                    Spacer()
                    dotLabel(deliverySummary(record), Self.needsAttention(record) ? .orange : .green)
                }
                if let error = record.attempts.last?.error, !error.isEmpty { Text(L(error)).font(.caption).foregroundStyle(.red) }
            }
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded = nil } } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).foregroundStyle(.secondary).help("收起")
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.05)))
        .padding(.vertical, 2)
    }
    /// One line on how the text reached the target, e.g. "已插入 · 剪贴板粘贴，已回读确认".
    func deliverySummary(_ record: Recording) -> String {
        var parts = [record.latestStatus == "succeeded" ? insertion(record.insertion) : status(record.latestStatus)]
        if let delivery = record.attempts.last?.delivery {
            if let route = ["pid_unicode": "文字事件", "ax_cell_value": "整格写入", "paste_restore": "剪贴板粘贴"][delivery.route] {
                parts.append(route + (["preserved_document", "complete_output"].contains(delivery.confirmation) ? "，已回读确认" : ""))
            }
        }
        return parts.joined(separator: " · ")
    }
    func time(_ record: Recording) -> some View {
        Text(record.created.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 58, alignment: .leading)
    }
    @ViewBuilder func meta(_ record: Recording, always: Bool = false) -> some View {
        let quiet = record.latestStatus == "succeeded" && ["inserted", "unchanged"].contains(record.insertion) && !record.deleting
        if !quiet || always {
            HStack(spacing: 6) {
                if record.latestStatus != "succeeded" { dotLabel(status(record.latestStatus), ["failed": .red, "raw_fallback": .orange, "cancelled": .gray].first { $0.key == record.latestStatus }?.value ?? .gray) }
                if !["unchanged"].contains(record.insertion) || always { dotLabel(insertion(record.insertion), Self.needsAttention(record) ? .gray : .green) }
                if record.deleting { dotLabel("待清理", .orange) }
            }
        }
        if let error = record.attempts.last?.error, !error.isEmpty { Text(L(error)).font(.caption).foregroundStyle(.red) }
    }
    func dotLabel(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(L(text)).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
    @ViewBuilder func actions(_ record: Recording) -> some View {
        Button("详情与版本") { detail = record }
        Button("重新识别音频") { model.retry(record, kind: "recognize") }.disabled(model.busy || !hasAudio(record))
        Button("重新整理文字") { model.retry(record, kind: "rewrite") }.disabled(model.busy || record.displayed?.raw.isEmpty != false)
        Button("播放音频") { model.play(record) }.disabled(!hasAudio(record))
        Button("导出音频") { model.export(record) }.disabled(!hasAudio(record))
        Button("导出问题报告") { model.feedback() }
        Divider(); Button("删除记录与音频", role: .destructive) { deleteRecord = record }.disabled(model.busy)
    }
    func dayTitle(_ day: Date) -> String {
        Calendar.current.isDateInToday(day) ? "今天" : Calendar.current.isDateInYesterday(day) ? "昨天" : day.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday(.wide))
    }
    func hasAudio(_ record: Recording) -> Bool { model.store?.audioURL(record).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}
func status(_ value: String) -> String { ["pending":"等待处理", "recording":"录音中", "recognizing":"正在识别", "rewriting":"正在整理", "succeeded":"已完成", "raw_fallback":"整理暂不可用，已保留原文", "failed":"失败", "cancelled":"已取消"][value] ?? value }
func insertion(_ value: String) -> String { ["not_attempted":"未自动插入", "inserted":"已插入", "input_text_present":"文字已写入；请核对原有内容", "input_dispatched":"已尝试输入，请核对文字", "input_unconfirmed":"送达未确认，请先核对文字", "paste_dispatched":"旧版：已尝试系统粘贴", "saved_only":"已保存，可复制", "unknown":"写入结果不明，请检查目标", "failed":"插入失败", "unsupported":"此输入框暂不支持自动写入", "unchanged":"输入位置已有相同文字", "clipboard_unconfirmed":"旧版：粘贴未确认"][value] ?? value }

struct InputDeliveryDetails: View {
    let evidence: InputDeliveryEvidence
    private var capability: String {
        ["readable_text": "正文与选区可回读", "readable_document": "正文可回读，选区未验证", "opaque_text": "文字控件，正文不可回读", "unique_writable_cell": "唯一可写单元格"][evidence.capture.capability] ?? "输入位置未确认"
    }
    private var route: String { ["pid_unicode": "文字事件", "ax_cell_value": "整格写入", "paste_restore": "临时剪贴板粘贴（已恢复原剪贴板）"][evidence.route] ?? "尚未选择路线" }
    private var confirmation: String {
        if evidence.status == "inspect_only" { return "仅检查输入位置，未尝试写入" }
        return ["preserved_document": "完整输出与原有正文保留已确认", "complete_output": "完整新文字已出现，原有内容保留未确认", "dispatch_only": "仅确认事件派发，请核对目标文字", "pending": "结果未知，请核对目标文字"][evidence.confirmation] ?? "送达未确认"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("捕获：\(capability)")
            if evidence.dispatchAttempted == nil { Text("派发：\(route)，实际是否派发未知；预定 \(evidence.plannedSegments) 段") }
            else if evidence.dispatchAttempted == true { Text("派发：\(route)，已完成 \(evidence.dispatchedSegments)/\(evidence.plannedSegments) 段") }
            else { Text("派发：未派发") }
            Text("确认：\(confirmation)")
            if let stage = evidence.failureStage { Text("未确认阶段：\(stage) · \(evidence.failureReason ?? "未知")") }
        }.font(.caption).textSelection(.enabled)
    }
}
struct RecordDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let recordID: String
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("录音详情与处理版本").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            if let record = model.records.first(where: { $0.id == recordID }) {
                Text("\(record.created.formatted()) · \(Int(record.duration)) 秒 · \(insertion(record.insertion))").font(.system(size: 13)).foregroundStyle(.secondary)
                if let diagnostic = record.insertionDetail, !diagnostic.isEmpty {
                    DisclosureGroup("输入诊断") { Text(diagnostic).font(.caption).textSelection(.enabled) }
                }
                if record.insertion == "input_text_present" {
                    Text("已确认新文字出现，但未能核验原有内容是否完整保留。请核对原有内容；本次未学习修改。").font(.caption).foregroundStyle(.secondary)
                }
                if record.insertion == "saved_only", record.insertionDetail?.hasPrefix("interaction_type_") == true {
                    Text("处理期间发生了键鼠操作，为避免写入错误位置，本次仅保存文字。").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Button("播放音频") { model.play(record) }; Button("编辑当前结果") { draft = record.text; editing = true }.disabled(model.busy || record.deleting) }
                if editing { TextEditor(text: $draft).font(.body).frame(height: 100).padding(6).outlined(radius: 8); HStack { Button("放弃") { editing = false }; Button("保存为新版本") { model.edit(record, text: draft); editing = false }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy) } }
                ScrollView { VStack(alignment: .leading, spacing: 14) { ForEach(record.attempts.reversed()) { attempt in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(status(attempt.status)) · \(attempt.started.formatted())").font(.headline)
                        Text("原始转写").font(.caption).foregroundStyle(.secondary); Text(attempt.raw.isEmpty ? L("尚无原始转写") : attempt.raw).textSelection(.enabled)
                        Text(L(attempt.status == "raw_fallback" ? "保留原文（未经整理）" : "整理结果")).font(.caption).foregroundStyle(.secondary); Text(attempt.result.isEmpty ? "尚无整理结果" : attempt.result).textSelection(.enabled)
                        if let response = attempt.modelResult, response != attempt.result {
                            DisclosureGroup("模型返回文本（本机处理前）") { Text(response).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        if !attempt.error.isEmpty { Text(L(attempt.error)).foregroundStyle(.red) }
                        if attempt.status == "succeeded", !attempt.rewriteModel.isEmpty {
                            Text("整理模型：\(attempt.rewriteModel)\(attempt.rewriteDiagnostic?.hasPrefix("model_unchanged") == true || (attempt.modelResult ?? attempt.result) == attempt.raw ? " · 模型返回文本与原文相同" : "")").font(.caption).foregroundStyle(.secondary)
                        }
                        if attempt.rewriteDiagnostic?.contains("local_stutter_cleanup") == true {
                            Text("本机另清理了连续代词口吃；原始转写保留。").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("识别 \(attempt.sttMS.map { "\($0) ms" } ?? "未知") · 整理 \(attempt.rewriteMS.map { "\($0) ms" } ?? "未知")").font(.caption).foregroundStyle(.secondary)
                        if let input = attempt.insertionMS { Text("输入 \(input) ms").font(.caption).foregroundStyle(.secondary) }
                        if let total = attempt.totalMS { Text("本次处理总耗时 \(total) ms").font(.caption).foregroundStyle(.secondary) }
                        if let trace = attempt.trace {
                            DisclosureGroup("分阶段耗时与输入确认") {
                                Text("\(trace.origin == "stop_requested" ? "停止录音起" : "处理起")至状态检查点：\(Int(trace.elapsedMS)) ms；阶段可能重叠，不能相加。").font(.caption)
                                Text("最后语音帧与单独上传耗时：未测量。检查点自己的保存结束时间未写入此快照。").font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(trace.spans.enumerated()), id: \.offset) { _, span in
                                    Text("\(span.stage)：\(span.durationMS.map { "\(Int($0)) ms" } ?? "未知") · \(span.outcome)").font(.caption)
                                }
                                ForEach(Array(trace.requests.enumerated()), id: \.offset) { _, request in
                                    Text("\(request.stage)：\(Int(request.clientMS)) ms").font(.caption)
                                }
                                if trace.flags.contains("context_target_changed") { Text("整理期间输入位置变化；本次跳过自动学习。").font(.caption) }
                                if let delivery = attempt.delivery {
                                    InputDeliveryDetails(evidence: delivery)
                                }
                            }
                        }
                        if attempt.sttDiagnostic != nil || attempt.rewriteDiagnostic != nil {
                            DisclosureGroup("请求诊断") {
                                if let value = attempt.sttDiagnostic { Text("识别：" + value).font(.caption).textSelection(.enabled) }
                                if let value = attempt.rewriteDiagnostic { Text("整理：" + value).font(.caption).textSelection(.enabled) }
                            }
                        }
                        HStack { Button("复制原文") { model.copy(attempt.raw) }.disabled(attempt.raw.isEmpty); Button("基于此版本重新整理") { model.retry(record, kind: "rewrite", source: attempt) }.disabled(model.busy || attempt.raw.isEmpty) }
                    }.panel(padding: 16, radius: 12)
                } } }
            }
        }.padding(28).frame(width: 680, height: 560)
    }
}
/// Plays one recording and shows its real loudness envelope with playback progress.
@MainActor final class ClipPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var position: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    let url: URL
    init(url: URL) { self.url = url }
    func toggle() {
        if player == nil { player = try? AVAudioPlayer(contentsOf: url) }
        guard let player else { return }
        if player.isPlaying { player.pause(); stopTicking() } else { player.play(); playing = true; startTicking() }
    }
    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                if !player.isPlaying { self.stopTicking(); if player.currentTime == 0 { self.position = 0 } }
            }
        }
    }
    private func stopTicking() { timer?.invalidate(); timer = nil; playing = false }
    func stop() { player?.stop(); stopTicking() }
    /// RMS per bucket normalized to the loudest bucket; empty when the file cannot be read.
    nonisolated static func levels(url: URL, count: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return [] }
        let frames = Int(buffer.frameLength), step = max(1, frames / count)
        let values: [Float] = (0..<count).map { i in
            let start = i * step, end = min(frames, start + step)
            guard start < end else { return 0 }
            var sum: Float = 0; for j in start..<end { sum += data[j] * data[j] }
            return (sum / Float(end - start)).squareRoot()
        }
        let peak = values.max() ?? 0
        return peak > 0 ? values.map { $0 / peak } : values
    }
}

struct AudioStrip: View {
    let duration: TimeInterval
    @StateObject private var player: ClipPlayer
    @State private var levels: [Float] = []
    init(url: URL, duration: TimeInterval) { self.duration = duration; _player = StateObject(wrappedValue: ClipPlayer(url: url)) }
    var body: some View {
        let progress = duration > 0 ? player.position / duration : 0
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.canvas)
                    .frame(width: 24, height: 24).background(Color.primary, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(L(player.playing ? "暂停" : "播放录音"))
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule().fill(Double(index) / Double(max(1, levels.count)) < progress ? Theme.accent : Color.primary.opacity(0.22))
                        .frame(width: 2, height: max(3, 16 * CGFloat(level)))
                }
            }.frame(height: 18).accessibilityHidden(true)
            Spacer(minLength: 8)
            Text("\(clock(player.position)) / \(clock(duration))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .task { let url = player.url; levels = await Task.detached(priority: .utility) { ClipPlayer.levels(url: url, count: 56) }.value }
        .onDisappear { player.stop() }
    }
    func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter = "全部"
    @State private var editing: DictionaryEntry?
    @State private var searching = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var confirmingDelete = false
    @State private var notice: String?
    var body: some View {
        let entries = model.dictionary.filter { (filter == "全部" || $0.origin == filter) && (query.isEmpty || ([$0.term] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(query) }) }
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "词典") {
                HStack(spacing: 8) {
                    if selecting {
                        Button(L(selected.count == entries.count ? "取消全选" : "全选")) { selected = selected.count == entries.count ? [] : Set(entries.map(\.id)) }.buttonStyle(SoftCapsuleStyle())
                        Button("删除\(selected.isEmpty ? "" : " \(selected.count) 个")") { confirmingDelete = true }.buttonStyle(SoftCapsuleStyle()).foregroundStyle(.red).disabled(selected.isEmpty)
                        Button("完成") { selecting = false; selected = [] }.buttonStyle(PrimaryCapsuleStyle(tint: .primary, foreground: Theme.canvas))
                    } else {
                        Button("导入") { importWords() }.buttonStyle(SoftCapsuleStyle()).help("从 CSV 或文本文件导入，每行第一列一个词")
                        if !model.dictionary.isEmpty { Button("选择") { selecting = true }.buttonStyle(SoftCapsuleStyle()) }
                        Button { editing = DictionaryEntry(term: "") } label: { Label("新词", systemImage: "plus") }.buttonStyle(PrimaryCapsuleStyle(tint: .primary, foreground: Theme.canvas))
                    }
                }
            }
            HStack {
                PillPicker(selection: $filter, options: [("全部", "所有"), ("automatic", "自动学习"), ("manual", "手动添加"), ("builtin", "内置")],
                           symbols: ["automatic": ("sparkle", Theme.accent), "manual": ("pencil", .secondary), "builtin": ("pin", .secondary)])
                Spacer()
                if searching || !query.isEmpty { SearchField(prompt: "搜索词语或读法", text: $query).transition(.opacity.combined(with: .move(edge: .trailing))) }
                else {
                    Button { withAnimation(.easeOut(duration: 0.18)) { searching = true } } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32).background(Color.primary.opacity(0.055), in: Circle())
                    }.buttonStyle(.plain).help("搜索词语").accessibilityLabel("搜索词语")
                }
            }
            HStack(spacing: 6) {
                Circle().fill(model.config.learning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(L(model.config.learning ? "自动学习已开启：你在输入框里改正的人名和术语，稳定后会自动加入这里。" : "自动学习未开启，可在设置 → 个性化中启用。"))
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    Button { if selecting { if selected.remove(entry.id) == nil { selected.insert(entry.id) } } else { editing = entry } } label: {
                        HStack(spacing: 9) {
                            if selecting { Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").font(.system(size: 13)).foregroundStyle(selected.contains(entry.id) ? Theme.accent : .secondary).frame(width: 14) }
                            else { Image(systemName: icon(entry.origin)).font(.system(size: 11, weight: .semibold)).foregroundStyle(entry.origin == "automatic" ? Theme.learned : .secondary).frame(width: 14) }
                            Text(entry.term).font(.system(size: 13, weight: .medium)).lineLimit(1).foregroundStyle(entry.enabled ? .primary : .secondary).strikethrough(!entry.enabled)
                            Spacer(minLength: 0)
                            if !entry.enabled { Text("已停用").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }.padding(.horizontal, 14).frame(height: 42).frame(maxWidth: .infinity, alignment: .leading).outlined(radius: 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(L(entry.origin == "manual" ? "手动添加" : entry.origin == "builtin" ? "内置词条" : "自动学习"))
                        .accessibilityLabel("\(entry.term)，\(entry.origin == "manual" ? "手动添加" : entry.origin == "builtin" ? "内置词条" : "自动添加")\(entry.enabled ? "" : "，已停用")")
                }
            }
            if model.dictionary.isEmpty { ContentUnavailableView("添加第一个词条", systemImage: "book.closed", description: Text("词条作为模型参考；具体识别效果取决于服务能力。")) }
        }.padding(.trailing, 8).padding(.bottom, 24) }.sheet(item: $editing) { entry in DictionaryEditor(entry: entry).environmentObject(model) }
        .onChange(of: filter) { selected = [] }.onChange(of: query) { selected = [] }
        .confirmationDialog("删除 \(selected.count) 个词语？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { deleteSelected() }
        } message: { Text("自动学到的词删除后不会再被自动加回，手动添加不受影响。") }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好") { notice = nil } }
    }
    private func deleteSelected() {
        do {
            guard let store = model.store else { throw AppError("存储尚未就绪。") }
            try store.deleteDictionary(model.dictionary.filter { selected.contains($0.id) })
            try model.refresh(); selected = []; selecting = false
        } catch { notice = error.localizedDescription }
    }
    private func importWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let store = model.store else { throw AppError("存储尚未就绪。") }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else { throw AppError("文件超过 1 MB，请拆分后再导入。") }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw AppError("无法读取文件，请使用 UTF-8 编码的 CSV 或文本文件。") }
            let terms = TermDictionary.importedTerms(text)
            guard !terms.isEmpty else { throw AppError("文件中没有可导入的词语。") }
            let added = try store.importDictionary(terms)
            try model.refresh()
            notice = "已导入 \(added) 个词语" + (added < terms.count ? "，跳过 \(terms.count - added) 个（已存在、冲突或无效）" : "") + (terms.count == TermDictionary.importLimit ? "；单次最多 \(TermDictionary.importLimit) 个" : "")
        } catch { notice = error.localizedDescription }
    }
    func icon(_ origin: String) -> String { origin == "automatic" ? "sparkle" : origin == "builtin" ? "pin" : "pencil" }
}
struct DictionaryEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var entry: DictionaryEntry
    @State private var validationError: String?
    // Just the word. Learned misrecognitions and the
    // built-in note stay in the data and keep working; they are not edited here.
    private var exists: Bool { model.dictionary.contains(where: { $0.id == entry.id }) }
    var body: some View { VStack(alignment: .leading, spacing: 14) {
        Text(L(exists ? "编辑词语" : "添加词语")).font(.system(size: 15, weight: .semibold))
        TextField("例如 Sayvia、人名或术语", text: $entry.term).textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 12).frame(height: 36).outlined(radius: 8).onSubmit { if !entry.term.trimmingCharacters(in: .whitespaces).isEmpty { saveOrDelete(deleting: false) } }
        if let validationError { Text(L(validationError)).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        HStack(spacing: 8) {
            if exists { Button("删除") { saveOrDelete(deleting: true) }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.red) }
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
            Button("保存") { saveOrDelete(deleting: false) }.keyboardShortcut(.defaultAction).controlSize(.large).disabled(entry.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.top, 2)
    }.padding(20).frame(width: 340) }
    private func saveOrDelete(deleting: Bool) {
        do {
            guard let store = model.store else { throw AppError("存储尚未就绪。") }
            if deleting { if let original = model.dictionary.first(where: { $0.id == entry.id }) { try store.deleteDictionary(original) } }
            else {
                entry.enabled = true // no switch any more; saving an old disabled word turns it back on
                let original = model.dictionary.first(where: { $0.id == entry.id })
                let clean = try TermDictionary.validated(entry, others: model.dictionary)
                // Renaming explicitly adopts an automatic or built-in word; saving it
                // unchanged keeps its source, evidence link and deletion semantics.
                let manual = original == nil || original?.term != clean.term || original?.hint != clean.hint || original?.aliases != clean.aliases
                _ = try store.saveDictionary(clean, manual: manual)
            }
            try model.refresh(); dismiss()
        } catch { validationError = error.localizedDescription }
    }
}
