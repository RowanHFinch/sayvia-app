import AppKit
import Carbon
import UniformTypeIdentifiers

struct ClipboardItemSnapshot {
    var representations: [String: Data]
}
struct ClipboardSnapshot {
    var changeCount: Int
    var items: [ClipboardItemSnapshot]
    static func capture(changeCount: () -> Int, itemTypes: () -> [[String]]?, read: (Int, String) -> Data?) -> ClipboardSnapshot? {
        let initial = changeCount()
        guard let items = itemTypes(), changeCount() == initial else { return nil }
        var snapshot: [ClipboardItemSnapshot] = []
        for (index, types) in items.enumerated() {
            var representations: [String: Data] = [:]
            for type in types {
                guard let data = read(index, type), changeCount() == initial else { return nil }
                representations[type] = data
            }
            snapshot.append(ClipboardItemSnapshot(representations: representations))
        }
        guard changeCount() == initial else { return nil }
        return ClipboardSnapshot(changeCount: initial, items: snapshot)
    }
}

// Primary route for text controls and fallback for targets whose AX focus cannot
// prove one. In order: snapshot, temporary text, one
// Command-V, restore. The user's clipboard is restored unless they copied
// something newer meanwhile.
@MainActor enum ClipboardPaste {
    // Readback that sees the pasted text restores at once. Otherwise the restore
    // follows the first read; a history app may read first, so never before
    // minWait either.
    // ponytail: an unreadable target hung past these bounds pastes the restored content.
    static let afterRead: TimeInterval = 0.2
    static let minWait: TimeInterval = 1
    static let maxWait: TimeInterval = 5
    static let sessionType = NSPasteboard.PasteboardType("io.github.rowanhfinch.sayvia.paste-session")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    struct Session { let saved: ClipboardSnapshot; let owned: Int; let id: String; let provider: Provider }
    private(set) static var pending: Session?
    final class Provider: NSObject, NSPasteboardItemDataProvider {
        let text: String
        var reads = 0
        var firstRead: TimeInterval?
        var landed = false
        init(_ text: String) { self.text = text }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            reads += 1; firstRead = firstRead ?? ProcessInfo.processInfo.systemUptime
            item.setString(text, forType: type)
        }
    }
    // Only failures that leave a concrete, responsive keyboard app. Never
    // secure input, user interaction, Sayvia itself, table/cell selections or
    // timeouts: a slow target could read the board after the restore.
    static func eligible(_ reason: String) -> Bool {
        let prefixes = ["non_text_target:", "input_control_unavailable:", "AXFocusedUIElement:", "AXValue:", "AXSelectedTextRanges:",
                        "invalid_selection_range", "invalid_marker_index", "marker_document_changed_or_inconsistent", "selected_markers_outside_element"]
        guard prefixes.contains(where: { reason.hasPrefix($0) }) else { return false }
        // A non-text focus must be a role seen wrapping editors (Muse reports its
        // composer as a button). File views paste text as files: Finder makes
        // a .textClipping from its desktop/icon view (AXScrollArea).
        if reason.hasPrefix("non_text_target:") {
            let role = reason.split(separator: ":").dropFirst(2).first.map(String.init) ?? ""
            guard ["AXButton", "AXWebArea", "AXGroup", "AXUnknown", "AXStaticText"].contains(role) else { return false }
        }
        return !["secure", "AXWindow", "AXApplication", "AXLayoutArea", "AXTable", "AXGrid", "AXCell", "AXOutline", "AXList", "cell_", "interaction", "deadline", ":-25204"].contains(where: { reason.contains($0) })
    }
    static func snapshot(_ board: NSPasteboard) -> ClipboardSnapshot? {
        ClipboardSnapshot.capture(changeCount: { board.changeCount }, itemTypes: { board.pasteboardItems?.map { $0.types.map(\.rawValue) } }, read: { index, type in
            guard let items = board.pasteboardItems, index < items.count else { return nil }
            return items[index].data(forType: NSPasteboard.PasteboardType(type))
        })
    }
    // Password managers mark secrets concealed and clear them on a timer that
    // our restore would defeat; leave such a clipboard alone.
    static func concealed(_ snapshot: ClipboardSnapshot) -> Bool { snapshot.items.contains { $0.representations[concealedType.rawValue] != nil } }
    // Images, PDFs and media may be rendered lazily by their source app; copying
    // them on every dictation would stall. Such clipboards keep the text-event route.
    static func holdsMedia(_ board: NSPasteboard) -> Bool {
        (board.pasteboardItems ?? []).contains { item in item.types.contains { type in
            UTType(type.rawValue).map { [.image, .pdf, .audiovisualContent].contains(where: $0.conforms) } ?? false
        } }
    }
    // Writes only if the board is still the snapshotted version.
    static func begin(_ text: String, saved: ClipboardSnapshot, to board: NSPasteboard) -> Session? {
        guard pending == nil, board.changeCount == saved.changeCount else { return nil }
        let id = UUID().uuidString, provider = Provider(text), item = NSPasteboardItem()
        // nspasteboard.org markers: clipboard history apps skip these items.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: concealedType)
        item.setString(id, forType: sessionType)
        guard item.setDataProvider(provider, forTypes: [.string]) else { return nil }
        board.clearContents()
        guard board.writeObjects([item]) else { put(saved, to: board); return nil }
        let session = Session(saved: saved, owned: board.changeCount, id: id, provider: provider)
        pending = session; return session
    }
    @discardableResult static func put(_ snapshot: ClipboardSnapshot, to board: NSPasteboard) -> Bool {
        board.clearContents()
        let items = snapshot.items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.representations { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        return items.isEmpty || board.writeObjects(items)
    }
    // "restored", "skipped_newer_copy" (a newer user copy wins) or "failed".
    @discardableResult static func restore(_ session: Session, to board: NSPasteboard) -> String {
        guard pending?.id == session.id else { return "already_restored" }
        pending = nil
        guard board.changeCount == session.owned, board.string(forType: sessionType) == session.id else { return "skipped_newer_copy" }
        return put(session.saved, to: board) ? "restored" : "failed"
    }
    // Waits for the target's read (bounded), then restores.
    static func finish(_ session: Session, to board: NSPasteboard, posted: Bool) async -> String {
        let started = ProcessInfo.processInfo.systemUptime
        while posted {
            let now = ProcessInfo.processInfo.systemUptime
            if now - started >= maxWait || session.provider.landed { break }
            if let read = session.provider.firstRead, now - read >= afterRead, now - started >= minWait { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return restore(session, to: board)
    }
    // Quit within the wait must not strand the temporary text.
    static func restorePending(_ board: NSPasteboard = .general) { if let pending { restore(pending, to: board) } }
    // The key that types "v" while Command is held in the current layout
    // (Dvorak, AZERTY, "Dvorak - QWERTY ⌘"...). IMEs such as Pinyin carry no
    // layout data, so fall back to their ASCII-capable layout, then ANSI V.
    static func commandVKeyCode() -> CGKeyCode {
        for copy in [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource] {
            guard let source = copy()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            if let code = keyCode(for: "v", layout: data, modifiers: UInt32((cmdKey >> 8) & 0xFF)) { return code }
        }
        return 0x09
    }
    static func keyCode(for character: Character, layout: Data, modifiers: UInt32) -> CGKeyCode? {
        layout.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0, length = 0, chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == String(character) { return CGKeyCode(code) }
            }
            return nil
        }
    }
    static func commandV(pid: pid_t, keyCode: CGKeyCode? = nil, post: ((CGEvent) -> Void)? = nil) -> Bool {
        let keyCode = keyCode ?? commandVKeyCode()
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        var events: [CGEvent] = []
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return false }
            event.flags = .maskCommand; event.setIntegerValueField(.eventSourceUserData, value: Hotkeys.insertionEventTag)
            events.append(event)
        }
        for event in events { if let post { post(event) } else { event.postToPid(pid) } }
        return true
    }
}
