import Foundation
import CSQLite

@MainActor
final class Store {
    let root: URL
    let audio: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("io.github.rowanhfinch.sayvia", isDirectory: true)
        audio = self.root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(self.root.appendingPathComponent("sayvia.sqlite").path, &db) == SQLITE_OK else { throw AppError("无法打开历史数据库。") }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS objects (kind TEXT NOT NULL, id TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(kind,id)); PRAGMA user_version=1;")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError("历史数据库写入失败，请检查磁盘空间。") }
    }
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    func save<T: Encodable>(_ value: T, kind: String, id: String) throws {
        let data = try encoder.encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO objects(kind,id,data) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw AppError("数据库不可写。") }
        defer { sqlite3_finalize(statement) }
        bind(kind, to: statement, at: 1); bind(id, to: statement, at: 2)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError("无法保存数据，请检查磁盘空间。") }
    }
    func load<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM objects WHERE kind=?", -1, &statement, nil) == SQLITE_OK else { throw AppError("无法读取数据库。") }
        defer { sqlite3_finalize(statement) }
        bind(kind, to: statement, at: 1)
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw AppError("历史数据库读取失败。") }
            result.append(try decoder.decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return result
    }
    func remove(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM objects WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw AppError("无法删除记录。") }
        defer { sqlite3_finalize(statement) }
        bind(kind, to: statement, at: 1); bind(id, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError("删除失败。") }
    }
    func audioURL(_ recording: Recording) -> URL? {
        guard !recording.audioName.isEmpty, recording.audioName == URL(fileURLWithPath: recording.audioName).lastPathComponent else { return nil }
        return audio.appendingPathComponent(recording.audioName)
    }
    func seedDictionary() throws {
        guard try load(Bool.self, kind: "dictionary_seed").first != true else { return }
        try transaction {
            let entries = try load(DictionaryEntry.self, kind: "dictionary")
            let brand = DictionaryEntry(id: "builtin.sayvia", term: "Sayvia", hint: "本语音输入软件的产品名，使用 Sayvia 拼写。仅在谈论该产品时参考；英语 severe、survey 等普通词保留原意。", origin: "builtin", aliases: ["赛维亚", "say via"])
            if !entries.contains(where: { TermDictionary.key($0.term) == TermDictionary.key(brand.term) }),
               let valid = try? TermDictionary.validated(brand, others: entries) {
                try save(valid, kind: "dictionary", id: valid.id)
            }
            // The marker also preserves an explicit deletion across launches.
            try save(true, kind: "dictionary_seed", id: "builtin-v1")
        }
    }
    // Learned words used to carry one fixed note that told the model nothing and
    // cost tokens on every rewrite; drop exactly that text, keep any other note.
    static let legacyLearnedHint = "来自可靠修订；仅在语境符合该姓名或术语时参考，不作无条件替换。"
    func clearLegacyLearnedHints() throws {
        for var entry in try load(DictionaryEntry.self, kind: "dictionary") where entry.hint == Self.legacyLearnedHint {
            entry.hint = ""; try save(entry, kind: "dictionary", id: entry.id)
        }
    }
    func saveDictionary(_ entry: DictionaryEntry, manual: Bool = true) throws -> DictionaryEntry {
        var value = try TermDictionary.validated(entry, others: load(DictionaryEntry.self, kind: "dictionary"))
        if manual { value.origin = "manual"; value.sourceID = nil }
        try save(value, kind: "dictionary", id: value.id)
        return value
    }
    func deleteRecording(_ recording: Recording) throws {
        var pending = recording; pending.deleting = true
        try save(pending, kind: "recording", id: pending.id)
        do {
            if let url = audioURL(pending), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try transaction {
                let examples = try load(Correction.self, kind: "correction").filter { $0.recordingID == pending.id }
                let ids = Set(examples.map(\.id))
                for example in examples { try remove(kind: "correction", id: example.id) }
                for var preference in try load(Preference.self, kind: "preference") where preference.origin == "automatic" {
                    preference.evidenceIDs.removeAll { ids.contains($0) }
                    if preference.evidenceIDs.count < 2 { try remove(kind: "preference", id: preference.id) }
                    else { try save(preference, kind: "preference", id: preference.id) }
                }
                for entry in try load(DictionaryEntry.self, kind: "dictionary") where entry.sourceID.map(ids.contains) == true { try remove(kind: "dictionary", id: entry.id) }
                try remove(kind: "recording", id: pending.id)
            }
        } catch {
            pending.cleanupError = "音频或关联数据尚未清理，将在下次维护时重试。"
            try? save(pending, kind: "recording", id: pending.id)
            throw error
        }
    }
    func resetLearning() throws {
        try transaction {
            for example in try load(Correction.self, kind: "correction") { try remove(kind: "correction", id: example.id) }
            for preference in try load(Preference.self, kind: "preference") where preference.origin == "automatic" { try remove(kind: "preference", id: preference.id) }
            for entry in try load(DictionaryEntry.self, kind: "dictionary") where entry.origin == "automatic" { try remove(kind: "dictionary", id: entry.id) }
            for term in try load(String.self, kind: "dictionary_block") { try remove(kind: "dictionary_block", id: TermDictionary.key(term)) }
        }
    }
    // A learned word the user deleted or undid is never learned again
    // automatically; adding it by hand still works.
    func blockedTerms() throws -> Set<String> { Set(try load(String.self, kind: "dictionary_block").map(TermDictionary.key)) }
    func blockTerm(_ term: String) throws { try save(term, kind: "dictionary_block", id: TermDictionary.key(term)) }
    func deleteDictionary(_ entry: DictionaryEntry) throws { try deleteDictionary([entry]) }
    func deleteDictionary(_ entries: [DictionaryEntry]) throws {
        try transaction {
            for entry in entries {
                try remove(kind: "dictionary", id: entry.id)
                if entry.origin == "automatic" { try blockTerm(entry.term) }
            }
        }
    }
    // Imported words are manual. Existing, conflicting or invalid words are
    // skipped, never overwritten; returns how many were added.
    func importDictionary(_ terms: [String]) throws -> Int {
        var current = try load(DictionaryEntry.self, kind: "dictionary"), added = 0
        try transaction {
            for term in terms {
                guard let value = try? TermDictionary.validated(DictionaryEntry(term: term), others: current) else { continue }
                try save(value, kind: "dictionary", id: value.id); current.append(value); added += 1
            }
        }
        return added
    }
    func setCorrectionEnabled(_ example: Correction) throws {
        try transaction {
            try save(example, kind: "correction", id: example.id)
            if !example.enabled {
                for entry in try load(DictionaryEntry.self, kind: "dictionary") where entry.sourceID == example.id { try remove(kind: "dictionary", id: entry.id) }
                for var preference in try load(Preference.self, kind: "preference") where preference.origin == "automatic" && preference.evidenceIDs.contains(example.id) {
                    preference.enabled = false
                    try save(preference, kind: "preference", id: preference.id)
                }
            }
        }
    }
    func deleteCorrection(_ id: String) throws { try transaction { try removeCorrection(id) } }
    // Undo of a learning toast: drop its evidence and new words, put merged words
    // back as they were, and keep the undone words from being learned again.
    func undoLearning(_ id: String, restoring entries: [DictionaryEntry], blocking terms: [String]) throws {
        try transaction {
            // Reset or deleting the evidence already cleared this learning.
            guard try load(Correction.self, kind: "correction").contains(where: { $0.id == id }) else { return }
            try removeCorrection(id)
            for entry in entries { try save(entry, kind: "dictionary", id: entry.id) }
            for term in terms { try blockTerm(term) }
        }
    }
    private func removeCorrection(_ id: String) throws {
        try remove(kind: "correction", id: id)
        for var preference in try load(Preference.self, kind: "preference") where preference.origin == "automatic" && preference.evidenceIDs.contains(id) {
            preference.evidenceIDs.removeAll { $0 == id }
            if preference.evidenceIDs.count < 2 { try remove(kind: "preference", id: preference.id) }
            else { try save(preference, kind: "preference", id: preference.id) }
        }
        for entry in try load(DictionaryEntry.self, kind: "dictionary") where entry.sourceID == id { try remove(kind: "dictionary", id: entry.id) }
    }
    func recover() throws {
        for var record in try load(Recording.self, kind: "recording") where !record.deleting {
            var changed = false
            for i in record.attempts.indices where ["pending", "recognizing", "rewriting"].contains(record.attempts[i].status) {
                record.attempts[i].status = "failed"; record.attempts[i].error = "应用退出中断了处理，可重试。"; changed = true
            }
            if record.attempts.isEmpty { var attempt = Attempt(); attempt.status = "cancelled"; attempt.error = "录音被中断，本地音频如完整可重试。"; record.attempts.append(attempt); changed = true }
            if changed { try save(record, kind: "recording", id: record.id) }
        }
    }
}
