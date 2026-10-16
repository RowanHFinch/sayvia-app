import Foundation
import NaturalLanguage

// The UI is written in Chinese; English comes from en.lproj/Localizable.strings,
// keyed by the Chinese text. SwiftUI looks up Text/Button literals itself;
// strings held in variables (titles, status messages, errors) go through L().
let uiLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hans")
func L(_ text: String) -> String { Bundle.main.localizedString(forKey: text, value: text, table: nil) }

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    static let noSpeech = "没有识别到文字，请检查麦克风或录音。"
    var isNoSpeech: Bool { message == Self.noSpeech }
}

struct Attempt: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind = "initial"
    var sourceID: String?
    var status = "pending"
    var raw = ""
    var result = ""
    var error = ""
    var started = Date()
    var finished: Date?
    var sttModel = ""
    var rewriteModel = ""
    var sttMS: Int?
    var rewriteMS: Int?
    var totalMS: Int?
    var insertionMS: Int?
    var sttDiagnostic: String?
    var rewriteDiagnostic: String?
    var modelResult: String?
    var trace: LatencyTrace?
    var delivery: InputDeliveryEvidence?
}

struct Recording: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var created = Date()
    var duration: TimeInterval = 0
    var audioName: String = ""
    var targetApp = ""
    var insertion = "not_attempted"
    var insertionDetail: String?
    var attempts: [Attempt] = []
    var successfulID: String?
    var deleting = false
    var cleanupError = ""
    var displayed: Attempt? { attempts.first(where: { $0.id == successfulID }) ?? attempts.last }
    var text: String { guard let a = displayed else { return "" }; return a.result.isEmpty ? a.raw : a.result }
    var latestStatus: String { attempts.last?.status ?? "recording" }
}

struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var term: String
    var hint = ""
    var origin = "manual"
    var sourceID: String?
    var aliases: [String] = []
    var enabled = true

    enum CodingKeys: String, CodingKey { case id, term, hint, origin, sourceID, aliases, enabled }
    init(id: String = UUID().uuidString, term: String, hint: String = "", origin: String = "manual", sourceID: String? = nil, aliases: [String] = [], enabled: Bool = true) {
        self.id = id; self.term = term; self.hint = hint; self.origin = origin; self.sourceID = sourceID
        self.aliases = aliases; self.enabled = enabled
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); term = try values.decode(String.self, forKey: .term)
        hint = try values.decodeIfPresent(String.self, forKey: .hint) ?? ""
        origin = try values.decodeIfPresent(String.self, forKey: .origin) ?? "manual"
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
struct Preference: Codable, Identifiable {
    var id = UUID().uuidString
    var instruction: String
    var scope = ""
    var enabled = true
    var origin = "manual"
    var evidenceIDs: [String] = []
}
struct Correction: Codable, Identifiable {
    var id = UUID().uuidString
    var recordingID: String
    var attemptID: String
    var before: String
    var after: String
    var scope: String
    var created = Date()
    var enabled = true
}
struct Configuration: Codable {
    // Endpoints are derived from the provider choice (and Bailian workspace)
    // when settings change; empty until the user finishes setup.
    var sttURL = ""
    var rewriteURL = ""
    var sttModel = Provider.bailianBeijing.sttModel
    var rewriteModel = Provider.bailianBeijing.rewriteModel
    var sttProvider: String? = nil
    var rewriteProvider: String? = nil
    var bailianWorkspace: String? = nil
    var language = ""
    var retentionDays = 0
    var onboardingDone = false
    var learning = false
    var useFn = true
    var inputDeviceID = ""
    // Optional fields keep existing configuration JSON compatible.
    var realtimeCandidate: Bool? = nil
    var overlapContextPreparation: Bool? = nil
    var interactionSounds: Bool? = nil
    // nil means on: the rewrite may read visible window text near the input field.
    var screenContext: Bool? = nil
    var recognitionProvider: Provider { sttProvider.flatMap(Provider.init) ?? .bailianBeijing }
    var cleanupProvider: Provider { rewriteProvider.flatMap(Provider.init) ?? .bailianBeijing }
    /// Realtime runs only on Bailian streaming ASR; other providers use file recognition. On by default.
    // Models whose "-streaming" twin exists in both regions (Model Studio docs, 2026-10-15).
    static let realtimeModels = ["qwen-audio-3.1-asr-flash", "qwen-audio-3.0-asr-flash"]
    var realtime: Bool { realtimeCandidate != false && ModelService.isBailianASR(sttURL) && Self.realtimeModels.contains(sttModel) }
    /// Preset endpoints always follow the provider and workspace; custom keeps what was typed.
    mutating func applyProviders() {
        let workspace = bailianWorkspace ?? ""
        if let region = Provider.region(workspace) {
            if recognitionProvider.isBailian { sttProvider = region.rawValue }
            if cleanupProvider.isBailian { rewriteProvider = region.rawValue }
        }
        if recognitionProvider != .custom { sttURL = recognitionProvider.sttURL(workspace: workspace) }
        if cleanupProvider != .custom { rewriteURL = cleanupProvider.rewriteURL(workspace: workspace) }
    }
    var realtimeURL: String? { URL(string: sttURL)?.host.map { "wss://\($0)/api-ws/v1/inference" } }
}

// Endpoint presets for bring-your-own-key. A preset fills the endpoint and a
// default model; the model stays editable. Bailian uses the workspace-dedicated
// domain, which Alibaba recommends; the shared DashScope domain gets no new
// features after 2026-09-30. Any OpenAI-compatible provider works as "custom".
enum Provider: String, CaseIterable, Identifiable {
    case bailianBeijing, bailianSingapore, openAI, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bailianBeijing: "阿里云百炼（北京）"
        case .bailianSingapore: "阿里云百炼（新加坡）"
        case .openAI: "OpenAI"
        case .custom: "自定义（OpenAI 兼容）"
        }
    }
    var isBailian: Bool { self == .bailianBeijing || self == .bailianSingapore }
    private func base(workspace: String) -> String? {
        switch self {
        case .bailianBeijing, .bailianSingapore:
            guard let workspace = Self.workspaceID(workspace) else { return nil }
            return "https://\(workspace).\(self == .bailianBeijing ? "cn-beijing" : "ap-southeast-1").maas.aliyuncs.com"
        case .openAI: return "https://api.openai.com"
        case .custom: return nil
        }
    }
    func sttURL(workspace: String) -> String {
        guard let base = base(workspace: workspace) else { return "" }
        return base + (isBailian ? "/api/v1/services/aigc/multimodal-generation/generation" : "/v1/audio/transcriptions")
    }
    func rewriteURL(workspace: String) -> String {
        guard let base = base(workspace: workspace) else { return "" }
        return base + (isBailian ? "/compatible-mode/v1/chat/completions" : "/v1/chat/completions")
    }
    // Both regions list these (Model Studio docs, checked 2026-10-15); the
    // realtime model is the same name with "-streaming".
    var sttModel: String { isBailian ? "qwen-audio-3.1-asr-flash" : self == .openAI ? "whisper-1" : "" }
    var rewriteModel: String { isBailian ? "qwen3.8-omni-flash" : self == .openAI ? "gpt-4o-mini" : "" }
    static func region(_ pasted: String) -> Provider? {
        let text = pasted.lowercased()
        return text.contains(".ap-southeast-1.") ? .bailianSingapore : text.contains(".cn-beijing.") ? .bailianBeijing : nil
    }
    /// Accepts a bare workspace ID or a pasted workspace domain/URL.
    static func workspaceID(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = URL(string: text)?.host { text = host }
        if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) }
        guard !text.isEmpty, text.count <= 64, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return text
    }
}

// Pure checks shared by persistence and native integration.
enum Safety {
    private static let latinTerms = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9+#.-]{0,38}[A-Za-z0-9+#]")
    static func prefixUTF16(_ value: String, limit: Int) -> String {
        var count = 0, end = value.startIndex
        for character in value {
            let size = character.utf16.count
            guard count + size <= limit else { break }
            count += size; end = value.index(after: end)
        }
        return String(value[..<end])
    }
    static func replacement(_ value: String, range: NSRange, text: String) -> String? {
        let length = (value as NSString).length
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { return nil }
        let units = value.utf16
        guard let start = String.Index(units.index(units.startIndex, offsetBy: range.location), within: value),
              let end = String.Index(units.index(units.startIndex, offsetBy: range.location + range.length), within: value) else { return nil }
        return value.replacingCharacters(in: start..<end, with: text)
    }
    // Mid-sentence insertion (text follows the caret on the same line) drops a
    // closing full stop so the sentence continues. ？！ carry meaning and stay.
    static func fitPunctuation(_ text: String, after: String) -> String {
        guard let next = after.first(where: { $0 != " " && $0 != "\t" }), !next.isNewline else { return text }
        if text.hasSuffix("。") || (text.hasSuffix(".") && !text.hasSuffix("..")) { return String(text.dropLast()) }
        return text
    }
    // Where the dictated text sits in the field after insertion: right before
    // the caret, else its only occurrence. Ambiguous positions are not learned.
    static func insertedSpan(_ text: String, in value: String, caret: NSRange?) -> (prefix: String, suffix: String)? {
        let field = value as NSString, length = text.utf16.count
        guard length > 0 else { return nil }
        var found: NSRange?
        if let caret, caret.length == 0, caret.location >= length, caret.location <= field.length,
           field.substring(with: NSRange(location: caret.location - length, length: length)) == text {
            found = NSRange(location: caret.location - length, length: length)
        } else {
            let first = field.range(of: text, options: .literal)
            guard first.location != NSNotFound else { return nil }
            let rest = NSRange(location: first.location + 1, length: field.length - first.location - 1)
            guard field.range(of: text, options: .literal, range: rest).location == NSNotFound else { return nil }
            found = first
        }
        guard let found else { return nil }
        return (field.substring(to: found.location), field.substring(from: found.location + found.length))
    }
    // Several small fixes in one message still count; the budget is the total
    // edited characters, not the span between the first and last edit.
    static func correction(before: String, after: String) -> Bool {
        guard before != after, !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let a = Array(before), b = Array(after)
        let difference = b.difference(from: a)
        let changed = max(difference.removals.count, difference.insertions.count)
        // ponytail: conservative local edits only; broader style learning needs stronger attribution.
        return a.count >= 2 && changed <= (a.count < 4 ? 1 : max(2, a.count / 3)) && b.count <= a.count + 20
    }
    static func keepsLanguage(raw: String, result: String, terms: [DictionaryEntry] = []) -> Bool {
        func hanCount(_ value: String) -> Int { value.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count }
        func referenceText(_ text: String) -> String {
            var value = text
            for term in terms.flatMap({ [$0.term] + $0.aliases }).sorted(by: { $0.count > $1.count }) where !term.isEmpty {
                value = value.replacingOccurrences(of: term, with: "", options: .caseInsensitive)
            }
            value = value.replacingOccurrences(of: "(?<![\\p{Han}])(?:嗯+|呃+|啊+|哦+|唔+|那个)(?![\\p{Han}])", with: "", options: .regularExpression)
            return value
        }
        func meaningfulHan(_ text: String) -> Int {
            hanCount(text.replacingOccurrences(of: "(?<![\\p{Han}])[零〇一二两三四五六七八九十][零〇一二两三四五六七八九十百千万亿点]*(?![\\p{Han}])", with: "", options: .regularExpression))
        }
        let source = referenceText(raw), answer = referenceText(result)
        let original = meaningfulHan(source), rewritten = meaningfulHan(answer)
        // The Chinese span must survive even in an English-dominant utterance.
        // Fillers, numeric formatting and dictionary spellings are not translation.
        if original >= 4 || (original > 0 && hanCount(source) >= 4 && hanCount(source) * 2 >= source.count) { return rewritten >= max(2, original / 5) }
        if hanCount(raw) == 0 && raw.split(whereSeparator: \.isWhitespace).count >= 4 { return rewritten < 4 }
        return true
    }
    static func keepsDetail(raw: String, result: String) -> Bool {
        func length(_ value: String) -> Int {
            let sentences = value.components(separatedBy: CharacterSet(charactersIn: "。！？.!?\n"))
            return Set(sentences.map { $0.replacingOccurrences(of: "[嗯呃]", with: "", options: .regularExpression).filter { $0.isLetter || $0.isNumber } }).reduce(0) { $0 + $1.count }
        }
        // ponytail: a conservative size guard catches severe summaries, not all semantic omissions.
        // Exact repeated sentences and fillers don't count; numeric formatting may shorten ordinary dictation.
        let original = length(raw)
        return original < 60 || length(result) * 100 >= original * 45
    }
    static func keepsDecimalScale(raw: String, result: String) -> Bool {
        func matches(_ text: String, _ pattern: String) -> [String] {
            let expression = try! NSRegularExpression(pattern: pattern)
            let source = text as NSString
            return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range).replacingOccurrences(of: ",", with: "") }
        }
        let decimalPattern = "(?<![\\d.])(?:\\d{1,3}(?:,\\d{3})+|\\d+)\\.\\d+(?!\\d|\\.\\d)"
        let integerPattern = "(?<![\\d.,])(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?!\\d|[.,]\\d)"
        let originalIntegers = Set(matches(raw, integerPattern))
        let resultIntegers = Set(matches(result, integerPattern))
        let resultDecimals = Set(matches(result, decimalPattern))
        for number in matches(raw, decimalPattern) where !resultDecimals.contains(number) {
            let flattened = number.replacingOccurrences(of: ".", with: "")
            if resultIntegers.contains(flattened) && !originalIntegers.contains(flattened) { return false }
        }
        // Detect a dropped decimal point, not general numeric equivalence. Do not
        // infer spoken prices or undo an explicit correction to an existing value.
        return true
    }
    static func cleanPronounStutters(_ text: String, raw: String, protectedTerms: [String]) -> String {
        // Require a clause/grammar boundary and a pronoun predicate; never apply
        // arbitrary character deduplication inside Chinese names or identifiers.
        let verbatim = "逐字|原样|一字不改|保留.{0,8}(重复|口吃)|不要.{0,8}(去重|删.{0,4}(重复|口吃))"
        guard raw.range(of: verbatim, options: .regularExpression) == nil else { return text }
        let source = text as NSString
        let quotes = try! NSRegularExpression(pattern: "\"[^\"]*(?:\"|$)|“[^”]*(?:”|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|`[^`]*(?:`|$)|'[^']*(?:'|$)")
        var protected = quotes.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        for term in protectedTerms where !term.isEmpty {
            var start = 0
            while start < source.length {
                let found = source.range(of: term, range: NSRange(location: start, length: source.length - start))
                if found.location == NSNotFound { break }
                protected.append(found); start = NSMaxRange(found)
            }
        }
        let repeats = try! NSRegularExpression(pattern: "(^|[\\s，。！？；：、,.;!?:]|但是|因为|所以|如果|而且|其实|包括|一些|让|由|给|对|说)([我你他她它])\\2+(?=的|能|会|要|在|是|有|想|觉得|认为|希望|可以|应该|需要|已经|没有|不能|不会|不要)")
        let result = NSMutableString(string: text)
        for match in repeats.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            result.replaceCharacters(in: match.range, with: source.substring(with: match.range(at: 1)) + source.substring(with: match.range(at: 2)))
        }
        return result as String
    }
    static func nearbyText(_ value: String, range: NSRange) -> String {
        guard replacement(value, range: range, text: "") != nil, let selection = Range(range, in: value) else { return "" }
        return "光标前：\(value[..<selection.lowerBound].suffix(800))\n选中文字：\(value[selection].prefix(400))\n光标后：\(value[selection.upperBound...].prefix(800))"
    }
    static func contextTerms(_ value: String) -> [String] {
        let text = String(value.prefix(2200)), tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
        if text.unicodeScalars.filter({ (0x3400...0x9FFF).contains($0.value) }).count >= 4 {
            tagger.setLanguage(.simplifiedChinese, range: text.startIndex..<text.endIndex)
        }
        var terms: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .personalName || tag == .organizationName { terms.append(String(text[range])) }
            return terms.count < 30
        }
        let latin = latinTerms
        terms += latin.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
        return Array(Set(terms)).sorted().prefix(50).map { $0 }
    }
    static func textChunks(_ text: String, limit: Int = 20) -> [[UniChar]] {
        var chunks: [[UniChar]] = [], chunk: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            // Keep newline/tab inside a text event: a leading control character is a Cocoa command.
            if chunk.count >= max(1, limit - 4), (units.first ?? 0) >= 32 { chunks.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }
    static func canType(_ chunks: [[UniChar]]) -> Bool {
        !chunks.isEmpty && chunks.allSatisfy { chunk in
            (1...20).contains(chunk.count) && (chunk.first ?? 0) >= 32 &&
            chunk.allSatisfy { ($0 >= 32 && $0 != 127 && !(0xF700...0xF8FF).contains($0)) || [9, 10, 13].contains($0) }
        }
    }
    static func canCommitText(_ text: String) -> Bool {
        !text.isEmpty && text.utf16.count <= 100_000 && text.utf16.allSatisfy {
            ($0 >= 32 && $0 != 127 && !(0xF700...0xF8FF).contains($0)) || [9, 10, 13].contains($0)
        }
    }
    static func expired(_ record: Recording, days: Int, now: Date = Date()) -> Bool {
        days > 0 && record.created < now.addingTimeInterval(-Double(days) * 86400)
    }
}
