import Foundation

// Turns a user's edit of dictated text into small candidates for a model to
// judge, then validates the model's answer before anything enters the
// dictionary: split the
// edit into separate changed spans with a little context, let a model apply a
// sound gate and a meaning gate, and accept only spans copied from the texts.
enum CorrectionReview {
    struct Candidate: Equatable {
        var original: String   // changed span plus context, as Sayvia typed it
        var corrected: String  // the same place after the user's edit
        var source: String     // the changed span alone, before and after
        var target: String
    }
    struct Decision: Equatable {
        var term: String
        var aliases: [String]
    }

    static let maximumCandidates = 8
    private static let maximumSegments = 24
    private static let maximumCharacters = 64
    private static let maximumCompactCharacters = 32
    private static let contextWeight = 6 // per side: an English word weighs 2, a Chinese character 1
    private static let contextCharacters = 40 // per side, so punctuation runs cannot grow a request

    private enum Kind { case word, compact, space, mark }
    private struct Segment { var text: String; var kind: Kind }

    static func isCompact(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
    private static func kind(_ character: Character) -> Kind {
        if character.unicodeScalars.contains(where: isCompact) { return .compact }
        if character.isWhitespace { return .space }
        if character.isLetter || character.isNumber || "'’_-.+#@&".contains(character) { return .word }
        return .mark
    }
    // English-like runs stay whole words; each Chinese/Japanese/Korean character is
    // its own segment so a one-character fix (王一 → 王祎) is a one-segment change.
    private static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        for character in text {
            let next = kind(character)
            if let last = result.last, last.kind == next, next == .word || next == .space { result[result.count - 1].text.append(character) }
            else { result.append(Segment(text: String(character), kind: next)) }
        }
        return result
    }
    // Sentence punctuation and quotes around a span are not part of a term; + # - inside names (C++, C#) are.
    private static let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。！？、；：,.!?;:…\"'“”‘’()（）[]【】《》<>「」『』"))
    private static func clean(_ text: String) -> String { text.trimmingCharacters(in: edges) }

    // Each replaced span (both sides non-empty) is a candidate. Pure insertions and
    // deletions are new writing, not misrecognitions. A rewrite of most of the
    // text gives no reliable pairing, so nothing is proposed.
    static func candidates(before: String, after: String) -> [Candidate] {
        let a = segments(before), b = segments(after)
        guard a.count <= 2000, b.count <= 2000 else { return [] }
        let difference = b.map(\.text).difference(from: a.map(\.text))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        // Unchanged segments appear in the same order on both sides.
        var hunks: [(Range<Int>, Range<Int>)] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) { i += 1; j += 1; continue }
            let start = (i, j)
            while i < a.count, removed.contains(i) { i += 1 }
            while j < b.count, inserted.contains(j) { j += 1 }
            hunks.append((start.0..<i, start.1..<j))
        }
        let replaced = hunks.filter { !$0.0.isEmpty && !$0.1.isEmpty }
        let meaningful = a.filter { $0.kind == .word || $0.kind == .compact }.count
        let changed = replaced.reduce(0) { $0 + max($1.0.count, $1.1.count) }
        guard changed <= max(4, meaningful / 2) else { return [] }

        func join(_ items: [Segment], _ range: Range<Int>) -> String { items[range].map(\.text).joined() }
        func weight(_ segment: Segment) -> Int { segment.kind == .word ? 2 : segment.kind == .compact ? 1 : 0 }
        var results: [Candidate] = [], seen = Set<String>()
        for (index, hunk) in hunks.enumerated() where !hunk.0.isEmpty && !hunk.1.isEmpty {
            let source = clean(join(a, hunk.0)), target = clean(join(b, hunk.1))
            guard hunk.0.count <= maximumSegments, hunk.1.count <= maximumSegments,
                  !source.isEmpty, target.contains(where: \.isLetter),
                  TermDictionary.key(source) != TermDictionary.key(target),
                  source.count <= maximumCharacters, target.count <= maximumCharacters,
                  !(source + target).unicodeScalars.contains(where: isCompact) || (source.count <= maximumCompactCharacters && target.count <= maximumCompactCharacters),
                  !(source + target).contains(where: \.isNewline),
                  seen.insert(source + "\u{0}" + target).inserted else { continue }
            // Context stops at the neighbouring hunks; unchanged segments match one to one.
            var before = 0, total = 0, characters = 0
            let lower = index > 0 ? hunks[index - 1].0.upperBound : 0
            while hunk.0.lowerBound - before > lower, total < contextWeight {
                let segment = a[hunk.0.lowerBound - before - 1]
                guard characters + segment.text.count <= contextCharacters else { break }
                total += weight(segment); characters += segment.text.count; before += 1
            }
            var after = 0; total = 0; characters = 0
            let upper = index + 1 < hunks.count ? hunks[index + 1].0.lowerBound : a.count
            while hunk.0.upperBound + after < upper, total < contextWeight {
                let segment = a[hunk.0.upperBound + after]
                guard characters + segment.text.count <= contextCharacters else { break }
                total += weight(segment); characters += segment.text.count; after += 1
            }
            results.append(Candidate(original: join(a, (hunk.0.lowerBound - before)..<(hunk.0.upperBound + after)),
                                     corrected: join(b, (hunk.1.lowerBound - before)..<(hunk.1.upperBound + after)), source: source, target: target))
            if results.count == maximumCandidates { break }
        }
        return results
    }

    // The model's answer is untrusted: every term and misrecognition must be
    // copied from the texts it was shown and cover the changed span (it may
    // widen to a full name, never move onto unchanged context); anything
    // malformed is dropped.
    static func decisions(from content: String, candidates: [Candidate]) -> [Decision] {
        guard let start = content.firstIndex(of: "["), let end = content.lastIndex(of: "]"), start < end,
              let items = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [[String: Any]] else { return [] }
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.utf16.count <= TermDictionary.termLimit && value == clean(value) &&
                value.contains(where: { $0.isLetter }) && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        var results: [Decision] = []
        for item in items.prefix(maximumCandidates * 2) {
            guard let id = item["id"] as? Int, candidates.indices.contains(id), let action = item["action"] as? String,
                  ["add", "add_term"].contains(action), let term = item["term"] as? String, valid(term),
                  candidates.contains(where: { $0.corrected.contains(term) && term.contains($0.target) }) else { continue }
            var aliases: [String] = []
            if action == "add" {
                guard let wrong = item["wrong"] as? String, valid(wrong), candidates[id].original.contains(wrong), wrong.contains(candidates[id].source),
                      TermDictionary.key(wrong) != TermDictionary.key(term) else { continue }
                aliases = [wrong]
            }
            if let index = results.firstIndex(where: { TermDictionary.key($0.term) == TermDictionary.key(term) }) {
                results[index].aliases += aliases.filter { alias in !results[index].aliases.contains { TermDictionary.key($0) == TermDictionary.key(alias) } }
            } else { results.append(Decision(term: term, aliases: aliases)) }
        }
        return results
    }
}
