import ApplicationServices
import Foundation

// usage: ax <pid> dump [maxDepth] | ax <pid> press <title-substring> [role]
let args = CommandLine.arguments
let pid = pid_t(args[1])!
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v
}

func label(_ e: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute].compactMap { attr(e, $0 as String).map { "\($0)" } }.filter { !$0.isEmpty }.joined(separator: " | ")
}

func walk(_ e: AXUIElement, _ d: Int, _ maxD: Int, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(e, d) { return true }
    guard d < maxD, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return false }
    for k in kids {
        if walk(k, d + 1, maxD, visit) { return true }
    }
    return false
}

let cmd = args[2]
if cmd == "dump" {
    let maxD = args.count > 3 ? Int(args[3])! : 12
    _ = walk(app, 0, maxD) { e, d in
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        print(String(repeating: " ", count: d) + role + " " + label(e).prefix(90)); return false
    }
} else if cmd == "toggleafter" {
    let needle = args[3]; var armed = false
    let found = walk(app, 0, 20) { e, _ in
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        if role == "AXStaticText", label(e) == needle { armed = true; return false }
        if armed, role == "AXCheckBox" {
            let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
            print("toggled checkbox after [\(needle)] was \(label(e)) -> \(r.rawValue)"); return true
        }
        return false
    }
    if !found { print("not found"); exit(2) }
} else if cmd == "press" {
    let needle = args[3]; let wantRole = args.count > 4 ? args[4] : nil
    let found = walk(app, 0, 20) { e, _ in
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        if let wantRole, role != wantRole { return false }
        guard label(e).contains(needle) else { return false }
        let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
        print("pressed \(role) [\(label(e))] -> \(r.rawValue)"); return true
    }
    if !found { print("not found: \(needle)"); exit(2) }
} else if cmd == "find" {
    // exit 0 when any element's label contains the needle (a wait-for primitive)
    let needle = args[3]
    let found = walk(app, 0, 30) { e, _ in label(e).contains(needle) }
    print(found ? "found" : "absent"); exit(found ? 0 : 1)
} else if cmd == "scrollto" {
    // AXScrollToVisible on the first element whose label contains the needle
    let needle = args[3]
    let found = walk(app, 0, 30) { e, _ in
        guard label(e).contains(needle) else { return false }
        let r = AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        print("scrolled to [\(label(e))] -> \(r.rawValue)"); return true
    }
    if !found { print("not found: \(needle)"); exit(2) }
}
