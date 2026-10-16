import Foundation

enum TermDictionary {
    static let termLimit = 100
    static let aliasLimit = 12
    static let hintLimit = 500

    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func mentioned(_ term: String, in context: String) -> Bool {
        guard !term.isEmpty else { return false }
        if term.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            return context.localizedCaseInsensitiveContains(term)
        }
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Za-z0-9_])"
        return context.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // A CSV or plain word list: the first column of each
    // row is a word; a header row, blank rows and quotes are dropped. Rows are
    // still validated one by one when saved.
    static let importLimit = 2000
    static func importedTerms(_ text: String) -> [String] {
        var terms: [String] = [], seen = Set<String>()
        for (index, row) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = row.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            var term = ""
            if line.hasPrefix("\"") {
                var rest = line.dropFirst()
                while let quote = rest.firstIndex(of: "\"") {
                    term += rest[..<quote]; rest = rest[rest.index(after: quote)...]
                    guard rest.first == "\"" else { break }
                    term += "\""; rest = rest.dropFirst()
                }
            } else { term = String(line.prefix { $0 != "," && $0 != "\t" }) }
            term = term.trimmingCharacters(in: .whitespaces)
            if index == 0, ["term", "terms", "word", "words", "词", "词语", "词条"].contains(key(term)) { continue }
            guard !term.isEmpty, seen.insert(key(term)).inserted else { continue }
            terms.append(term)
            if terms.count == importLimit { break }
        }
        return terms
    }

    static func validated(_ entry: DictionaryEntry, others: [DictionaryEntry]) throws -> DictionaryEntry {
        var value = entry
        value.term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        value.hint = entry.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        func validTerm(_ term: String) -> Bool {
            !term.isEmpty && term.utf16.count <= termLimit &&
                term.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } &&
                !term.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard validTerm(value.term) else { throw AppError("词语须包含文字或数字，不含换行或控制符，最多 100 个字符（部分符号占多个字符）。") }
        guard value.hint.utf16.count <= hintLimit else { throw AppError("词条说明最多 500 个字符（部分符号占多个字符）。") }
        var seen = Set([key(value.term)])
        value.aliases = entry.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
            .filter { !$0.isEmpty && seen.insert(key($0)).inserted }
        guard value.aliases.count <= aliasLimit, value.aliases.allSatisfy(validTerm) else {
            throw AppError("最多填写 12 个读法或误识别，每个最多 100 个字符（部分符号占多个字符），不含换行或控制符。")
        }
        let remaining = others.filter { $0.id != value.id }
        guard !remaining.contains(where: { key($0.term) == key(value.term) }) else { throw AppError("已有相同词语，请编辑现有词条。") }
        if value.enabled {
            let names = Set(([value.term] + value.aliases).map(key))
            if let conflict = remaining.first(where: { $0.enabled && !names.isDisjoint(with: ([$0.term] + $0.aliases).map(key)) }) {
                throw AppError("读法或误识别与「\(conflict.term)」冲突，请先调整对应词条。")
            }
        }
        return value
    }

    static func active(_ entries: [DictionaryEntry], context: String = "") -> [DictionaryEntry] {
        func rank(_ entry: DictionaryEntry) -> Int { entry.origin == "manual" ? 0 : entry.origin == "builtin" ? 1 : 2 }
        // Existing stores may contain duplicate or overlong entries. Omit invalid
        // references without deleting user data; stable ordering makes the cap predictable.
        let sorted = entries.filter(\.enabled).sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            let mentionedA = !context.isEmpty && ([$0.term] + $0.aliases).contains { mentioned($0, in: context) }
            let mentionedB = !context.isEmpty && ([$1.term] + $1.aliases).contains { mentioned($0, in: context) }
            if mentionedA != mentionedB { return mentionedA }
            return key($0.term) == key($1.term) ? $0.id < $1.id : key($0.term) < key($1.term)
        }
        var selected: [DictionaryEntry] = []
        for entry in sorted {
            var reference = entry
            reference.hint = Safety.prefixUTF16(reference.hint, limit: hintLimit)
            guard let clean = try? validated(reference, others: selected) else { continue }
            selected.append(clean)
            if selected.count == 100 { break }
        }
        return selected
    }

    static func recognitionTerms(_ entries: [DictionaryEntry], context: String = "") -> [String] {
        // Boost only canonical spellings. Boosting erroneous aliases would teach
        // the recognizer precisely the words the user is trying to avoid.
        let canonical = active(entries, context: context).map(\.term)
        let disabled = Set(entries.filter { !$0.enabled }.flatMap { [$0.term] + $0.aliases }.map(key)).subtracting(canonical.map(key))
        let terms = canonical + Safety.contextTerms(context).filter { !disabled.contains(key($0)) }
        var seen = Set<String>()
        return Array(terms.filter { !$0.isEmpty && $0.utf16.count <= termLimit && seen.insert(key($0)).inserted }.prefix(100))
    }

}
