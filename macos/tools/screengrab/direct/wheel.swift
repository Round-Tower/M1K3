import CoreGraphics
import Foundation

// usage: wheel <pid> <ticks> <deltaPerTick>  — scrolls the pid's largest window at 60% height
let pid = Int32(CommandLine.arguments[1])!
let ticks = Int(CommandLine.arguments[2])!
let delta = Int32(CommandLine.arguments[3])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: CGRect = .zero
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    if r.width * r.height > best.width * best.height { best = r }
}

guard best.width > 0 else { print("no window"); exit(2) }
let point = CGPoint(x: best.midX, y: best.minY + best.height * 0.6)
CGWarpMouseCursorPosition(point)
for _ in 0 ..< ticks {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
    e?.location = point
    e?.post(tap: .cghidEventTap)
    usleep(60000)
}

print("scrolled \(ticks)x\(delta) at \(point)")
