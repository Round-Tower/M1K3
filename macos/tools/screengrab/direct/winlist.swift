import CoreGraphics
import Foundation

let pidFilter = Int32(CommandLine.arguments.dropFirst().first ?? "0") ?? 0
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
    if pidFilter != 0, pid != pidFilter { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, pid, w[kCGWindowOwnerName as String] ?? "", w[kCGWindowName as String] ?? "", b["Width"] ?? 0, b["Height"] ?? 0, w[kCGWindowLayer as String] ?? 0)
}
