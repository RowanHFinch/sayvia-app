import ApplicationServices

// A table selection is an input target only when the provider identifies one
// writable cell. An application/window or a grid role alone is insufficient.
struct SelectedCell {
    let container: AXUIElement
    let element: AXUIElement
    let row: Int
    let column: Int

    static let containerRoles = ["AXTable", "AXGrid", "AXLayoutArea"]
    static let roles = containerRoles + ["AXCell"]

    @MainActor static func capture(in focus: AXUIElement,
                        query: (AXUIElement, String) -> (AXError, CFTypeRef?) = read,
                        writable: (AXUIElement, String) -> (AXError, Bool) = isWritable,
                        onFailure: (String) -> Void = { _ in }) -> SelectedCell? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var failed = false
        func fail(_ reason: String) { failed = true; onFailure(reason) }
        func ask(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard !failed, ProcessInfo.processInfo.systemUptime < deadline else { fail("cell_capture_deadline"); return nil }
            AXUIElementSetMessagingTimeout(node, 0.025)
            let (status, value) = query(node, name)
            guard ProcessInfo.processInfo.systemUptime < deadline else { fail("cell_capture_deadline"); return nil }
            if status == .success { return value }
            if ![AXError.attributeUnsupported, .noValue, .notImplemented].contains(status) { fail("cell_\(name):\(status.rawValue)") }
            return nil
        }
        guard let role = ask(focus, kAXRoleAttribute) as? String, roles.contains(role) else { return nil }
        var container = focus, visited = [focus]
        if role == "AXCell" {
            for _ in 0..<12 {
                guard let parent = ask(container, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { fail("cell_container_unavailable"); return nil }
                container = parent as! AXUIElement
                guard !visited.contains(where: { CFEqual($0, container) }) else { fail("cell_parent_cycle"); return nil }
                visited.append(container)
                if containerRoles.contains(ask(container, kAXRoleAttribute) as? String ?? "") { break }
            }
            guard containerRoles.contains(ask(container, kAXRoleAttribute) as? String ?? "") else { fail("cell_container_unavailable"); return nil }
        }
        let (selectionStatus, selectedCells) = query(container, kAXSelectedCellsAttribute)
        let cells: CFTypeRef?
        if selectionStatus == .success {
            guard let list = selectedCells as? [AXUIElement], list.count == 1 else { fail("cell_selection_missing_or_multiple"); return nil }
            cells = selectedCells
            if let children = ask(container, kAXSelectedChildrenAttribute) as? [AXUIElement],
               children.contains(where: { ask($0, kAXRoleAttribute) as? String == "AXCell" }),
               (children.count != 1 || !CFEqual(children[0], list[0])) { fail("cell_selection_inconsistent"); return nil }
        } else if [AXError.attributeUnsupported, .noValue, .notImplemented].contains(selectionStatus) {
            cells = ask(container, kAXSelectedChildrenAttribute)
        } else { fail("cell_\(kAXSelectedCellsAttribute):\(selectionStatus.rawValue)"); return nil }
        guard !failed else { return nil }
        guard let cells = cells as? [AXUIElement], cells.count == 1 else { fail("cell_selection_missing_or_multiple"); return nil }
        let cell = cells[0]
        guard ask(cell, kAXRoleAttribute) as? String == "AXCell",
              role != "AXCell" || CFEqual(focus, cell) else { fail("cell_selection_not_focused_cell"); return nil }
        // References can point outside the focused branch; prove containment
        // before reading any cell content or considering a write.
        guard InputTarget.isDescendant(cell, of: container, read: { ask($0, $1) }), !failed else { fail("cell_outside_focused_container"); return nil }
        guard ask(container, kAXEnabledAttribute) as? Bool != false,
              ask(cell, kAXEnabledAttribute) as? Bool != false,
              ask(cell, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              ask(cell, "AXIsEditable") as? Bool != false, !failed else { fail("cell_not_editable"); return nil }
        func index(_ name: String) -> Int? {
            guard let value = ask(cell, name), let range = InputTarget.selectionRange(value), range.location >= 0, range.length == 1 else { return nil }
            return range.location
        }
        guard let row = index(kAXRowIndexRangeAttribute), let column = index(kAXColumnIndexRangeAttribute), !failed else { fail("cell_coordinates_unavailable"); return nil }
        let (status, settable) = writable(cell, kAXValueAttribute)
        guard status == .success, settable, ProcessInfo.processInfo.systemUptime < deadline else { fail("cell_value_not_writable:\(status.rawValue)"); return nil }
        return SelectedCell(container: container, element: cell, row: row, column: column)
    }
    func matches(_ other: SelectedCell) -> Bool {
        CFEqual(container, other.container) && CFEqual(element, other.element) && row == other.row && column == other.column
    }
    static func read(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (status, value)
    }
    static func isWritable(_ element: AXUIElement, _ name: String) -> (AXError, Bool) {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        return (status, settable.boolValue)
    }
}
