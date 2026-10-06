#!/usr/bin/env swift
// make_vision_fixtures.swift — renders the ChatEval `vision` fixture images.
//
//   swift macos/tools/eval/make_vision_fixtures.swift macos/Sources/M1K3Eval/Resources/VisionFixtures
//
// Every image is DRAWN here, from fixed layouts, so the assets are ours (the
// repo is public — no scraped receipts or stock photos) and every answer the
// fixtures check is known by construction. Change a drawing → re-run → the
// fixture expectations in ChatEvalFixture.swift must still hold; the strings
// they check are the literals below.
//
// Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.8, Prior: none (new
// file; GEMMA_1_1_PLAN Stream A). Layouts are deliberately plain — the eval
// asks "can the brain read this", not "can it read this through noise".

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Drawing kit

func render(_ name: String, _ width: Int, _ height: Int, background: NSColor = .white, draw: () -> Void) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("bitmap \(name)") }
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Flip so layouts read top-down like a page.
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    background.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png \(name)") }
    try! png.write(to: outDir.appendingPathComponent("\(name).png"))
    print("wrote \(name).png (\(png.count / 1024) KB)")
}

func font(_ name: String, _ size: CGFloat, bold: Bool = false) -> NSFont {
    let base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
    return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
}

/// Text at a top-left point in the flipped canvas.
func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor = .black) {
    let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    NSGraphicsContext.saveGraphicsState()
    // Undo the flip locally so glyphs aren't mirrored.
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: x, y: y + font.ascender)
    ctx.scaleBy(x: 1, y: -1)
    attributed.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, fill: NSColor, radius: CGFloat = 0) {
    fill.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
}

func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ color: NSColor = .black, width: CGFloat = 1) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x1, y: y1))
    path.line(to: NSPoint(x: x2, y: y2))
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

let mono = "Menlo"
let sans = "Helvetica Neue"

// MARK: - Receipts

render("receipt-cafe", 520, 760, background: NSColor(white: 0.98, alpha: 1)) {
    text("HARBOUR CAFÉ", 150, 40, font(mono, 30, bold: true))
    text("12 Quay Street, Dungarvan", 120, 84, font(mono, 17))
    text("06/10/2026   14:32   Till 2", 110, 112, font(mono, 17))
    line(40, 150, 480, 150)
    let items = [("Flat white", "3.80"), ("Flat white", "3.80"), ("Scone + jam", "4.20"),
                 ("Soup of the day", "6.90"), ("Sparkling water", "2.50"), ("Brownie", "2.20")]
    for (index, item) in items.enumerated() {
        let y = 170 + CGFloat(index) * 40
        text(item.0, 50, y, font(mono, 20))
        text("€" + item.1, 380, y, font(mono, 20))
    }
    line(40, 420, 480, 420)
    text("TOTAL", 50, 440, font(mono, 26, bold: true))
    text("€23.40", 350, 440, font(mono, 26, bold: true))
    text("Card  ****4417", 50, 500, font(mono, 18))
    text("Thank you — see you again!", 100, 600, font(mono, 17))
}

render("receipt-hardware", 520, 700, background: NSColor(white: 0.97, alpha: 1)) {
    text("QUAY HARDWARE LTD", 110, 40, font(mono, 28, bold: true))
    text("Invoice 88213", 170, 84, font(mono, 18))
    line(40, 125, 480, 125)
    text("QTY  ITEM                 PRICE", 50, 140, font(mono, 17, bold: true))
    let items = [("2", "Wood screws (box)", "9.98"), ("4", "Brass hinges", "15.60"),
                 ("1", "Sandpaper pack", "5.25"), ("3", "Paint brush 2in", "8.85"),
                 ("1", "Wood glue 250ml", "6.40")]
    for (index, item) in items.enumerated() {
        let y = 180 + CGFloat(index) * 38
        text(item.0, 58, y, font(mono, 18))
        text(item.1, 105, y, font(mono, 18))
        text("€" + item.2, 390, y, font(mono, 18))
    }
    line(40, 385, 480, 385)
    text("TOTAL", 50, 400, font(mono, 22, bold: true))
    text("€46.08", 375, 400, font(mono, 22, bold: true))
}

// MARK: - Chart

render("chart-sales", 900, 600) {
    text("Monthly sales (units), H1 2026", 230, 24, font(sans, 28, bold: true))
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
    let values: [CGFloat] = [31, 38, 42, 67, 55, 49]
    let baseY: CGFloat = 520, scale: CGFloat = 5.5, barW: CGFloat = 90
    line(90, baseY, 840, baseY, width: 2)
    line(90, 90, 90, baseY, width: 2)
    for tick in stride(from: 0, through: 70, by: 10) {
        let y = baseY - CGFloat(tick) * scale
        text("\(tick)", 50, y - 10, font(sans, 15), .darkGray)
        line(86, y, 94, y)
    }
    for (index, month) in months.enumerated() {
        let x = 120 + CGFloat(index) * 120
        let h = values[index] * scale
        rect(x, baseY - h, barW, h, fill: NSColor(red: 0.16, green: 0.42, blue: 0.70, alpha: 1))
        text("\(Int(values[index]))", x + 30, baseY - h - 28, font(sans, 18, bold: true))
        text(month, x + 28, baseY + 12, font(sans, 18))
    }
}

// MARK: - Dialogs

func alert(_ name: String, title: String, body: [String], buttons: [String]) {
    render(name, 760, 360, background: NSColor(white: 0.88, alpha: 1)) {
        rect(40, 30, 680, 300, fill: NSColor(white: 0.97, alpha: 1), radius: 18)
        // A plain yellow warning triangle, drawn (no system icon assets).
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: 110, y: 70))
        tri.line(to: NSPoint(x: 150, y: 140))
        tri.line(to: NSPoint(x: 70, y: 140))
        tri.close()
        NSColor.systemYellow.setFill()
        tri.fill()
        text("!", 104, 92, font(sans, 36, bold: true))
        text(title, 180, 66, font(sans, 21, bold: true))
        for (index, row) in body.enumerated() {
            text(row, 180, 106 + CGFloat(index) * 26, font(sans, 17), NSColor(white: 0.2, alpha: 1))
        }
        for (index, button) in buttons.reversed().enumerated() {
            let x = 570 - CGFloat(index) * 150
            rect(x, 260, 130, 40, fill: index == 0 ? .systemBlue : NSColor(white: 0.85, alpha: 1), radius: 8)
            text(button, x + 20, 268, font(sans, 17), index == 0 ? .white : .black)
        }
    }
}

alert(
    "dialog-eject",
    title: "The disk “Backup” wasn’t ejected because",
    body: ["one or more programs may be using it.",
           "To eject the disk immediately, click the Force Eject button."],
    buttons: ["Try Again", "Force Eject"]
)

alert(
    "dialog-error-code",
    title: "The operation can’t be completed.",
    body: ["Some of the data in “report.pdf” can’t be read",
           "or written.", "(Error code -36)"],
    buttons: ["OK"]
)

// MARK: - Code screenshots

func code(_ name: String, _ lines: [String]) {
    render(name, 900, 80 + lines.count * 30, background: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)) {
        for (index, row) in lines.enumerated() {
            let y = 40 + CGFloat(index) * 30
            text(String(format: "%2d", index + 1), 20, y, font(mono, 18), NSColor(white: 0.45, alpha: 1))
            text(row, 70, y, font(mono, 18), NSColor(red: 0.86, green: 0.88, blue: 0.84, alpha: 1))
        }
    }
}

code("code-swift-crash", [
    "func total(of items: [Double]) -> Double {",
    "    var sum = 0.0",
    "    for i in 0...items.count {",
    "        sum += items[i]",
    "    }",
    "    return sum",
    "}",
])

code("code-python-function", [
    "import csv",
    "",
    "def parse_invoice(path):",
    "    with open(path) as handle:",
    "        rows = list(csv.DictReader(handle))",
    "    return sum(float(r[\"amount\"]) for r in rows)",
])

// MARK: - Whiteboard

render("whiteboard-pricing", 1000, 680, background: NSColor(white: 0.96, alpha: 1)) {
    let marker = "Marker Felt"
    let blue = NSColor(red: 0.1, green: 0.25, blue: 0.65, alpha: 1)
    let red = NSColor(red: 0.75, green: 0.12, blue: 0.12, alpha: 1)
    text("PRICING v2", 60, 40, font(marker, 48, bold: true), blue)
    text("• Free  —  €0  (3 docs)", 80, 140, font(marker, 36), blue)
    text("• Pro   —  €8 / mo", 80, 210, font(marker, 36), blue)
    text("• Team  —  €20 / mo per seat", 80, 280, font(marker, 36), blue)
    line(60, 380, 940, 380, NSColor(white: 0.6, alpha: 1), width: 2)
    text("ACTIONS", 60, 410, font(marker, 40, bold: true), red)
    text("Aoife → draft the FAQ by Friday", 80, 490, font(marker, 34), red)
    text("Ciarán → check VAT on Team tier", 80, 560, font(marker, 34), red)
}

// MARK: - Dense document page

render("doc-retention-policy", 850, 1100) {
    text("Data Handling Policy — Section 4", 60, 50, font("Times New Roman", 30, bold: true))
    let body = [
        "4.1  Scope. This section applies to every recording, transcript and derived",
        "summary produced by the call assistant on a member's device. It does not",
        "cover material a member exports by hand, which follows Section 6.",
        "",
        "4.2  Storage. Recordings are stored on the device that captured them and",
        "are never uploaded. Transcripts inherit the protection class of the",
        "recording they came from. Summaries are stored beside the transcript.",
        "",
        "4.3  Retention. Call recordings are retained for 90 days, after which they",
        "are deleted automatically. Transcripts are retained for 365 days unless",
        "the member pins them. Summaries are retained until the member deletes",
        "them, and are removed together with their transcript.",
        "",
        "4.4  Deletion. A member may delete any recording, transcript or summary",
        "at any time from Settings. Deletion is immediate and cannot be undone.",
        "Backups made by the operating system follow the system's own schedule.",
        "",
        "4.5  Access. No staff member can access recordings. Support requests",
        "that need a transcript must be sent by the member, who chooses what to",
        "share. Shared excerpts are deleted 30 days after the ticket closes.",
        "",
        "4.6  Review. This section is reviewed every twelve months, or sooner if",
        "the law in the member's jurisdiction changes.",
    ]
    for (index, row) in body.enumerated() {
        text(row, 60, 120 + CGFloat(index) * 36, font("Times New Roman", 21))
    }
}

// MARK: - Counting

render("count-shapes", 900, 600, background: NSColor(white: 0.99, alpha: 1)) {
    // Fixed, non-overlapping positions: 7 red circles, 3 blue squares.
    let circles: [(CGFloat, CGFloat)] = [(90, 80), (300, 60), (520, 120), (760, 90),
                                         (180, 330), (640, 380), (420, 470)]
    let squares: [(CGFloat, CGFloat)] = [(330, 250), (740, 260), (110, 480)]
    NSColor.systemRed.setFill()
    for (x, y) in circles {
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 80, height: 80)).fill()
    }
    for (x, y) in squares {
        rect(x, y, 80, 80, fill: .systemBlue)
    }
}

// MARK: - Timetable

render("timetable-bus", 820, 520) {
    text("Route 362  —  Waterford → Dungarvan", 60, 36, font(sans, 28, bold: true))
    text("Weekdays", 60, 84, font(sans, 20), .darkGray)
    let headers = ["Waterford", "Kilmacthomas", "Dungarvan"]
    let rows = [["07:05", "07:35", "08:05"], ["10:40", "11:10", "11:40"],
                ["14:20", "14:50", "15:20"], ["18:00", "18:30", "19:00"],
                ["21:45", "22:15", "22:45"]]
    for (col, header) in headers.enumerated() {
        text(header, 80 + CGFloat(col) * 240, 140, font(sans, 22, bold: true))
    }
    line(60, 180, 760, 180, width: 2)
    for (r, row) in rows.enumerated() {
        let y = 200 + CGFloat(r) * 56
        if r % 2 == 0 { rect(60, y - 10, 700, 52, fill: NSColor(white: 0.94, alpha: 1)) }
        for (col, time) in row.enumerated() {
            text(time, 80 + CGFloat(col) * 240, y, font(mono, 24))
        }
    }
}

// MARK: - Sign

render("sign-parking", 600, 760, background: NSColor(red: 0.55, green: 0.62, blue: 0.68, alpha: 1)) {
    rect(80, 60, 440, 640, fill: .white, radius: 20)
    // A red ring with a slash: the no-parking roundel, drawn.
    let ring = NSBezierPath(ovalIn: NSRect(x: 200, y: 100, width: 200, height: 200))
    NSColor(red: 0.1, green: 0.3, blue: 0.75, alpha: 1).setFill()
    ring.fill()
    ring.lineWidth = 22
    NSColor.systemRed.setStroke()
    ring.stroke()
    line(230, 130, 370, 270, .systemRed, width: 22)
    text("NO PARKING", 150, 340, font(sans, 44, bold: true))
    text("8am – 6pm", 190, 420, font(sans, 40))
    text("Mon – Sat", 200, 480, font(sans, 40))
    text("Tow-away zone", 185, 590, font(sans, 30), .systemRed)
}

// MARK: - Settings screenshot

render("ui-settings", 760, 460, background: NSColor(white: 0.93, alpha: 1)) {
    rect(40, 40, 680, 380, fill: .white, radius: 14)
    text("Network & Sharing", 70, 60, font(sans, 26, bold: true))
    let rows: [(String, String, Bool?)] = [("Wi-Fi", "On", true), ("Bluetooth", "Off", false),
                                           ("AirDrop", "Contacts Only", nil), ("Personal Hotspot", "Off", false)]
    for (index, row) in rows.enumerated() {
        let y = 130 + CGFloat(index) * 70
        line(70, y - 12, 690, y - 12, NSColor(white: 0.85, alpha: 1))
        text(row.0, 80, y + 6, font(sans, 22))
        if let isOn = row.2 {
            rect(600, y, 64, 36, fill: isOn ? .systemGreen : NSColor(white: 0.82, alpha: 1), radius: 18)
            rect(isOn ? 630 : 602, y + 2, 32, 32, fill: .white, radius: 16)
            text(row.1, 520, y + 6, font(sans, 20), .darkGray)
        } else {
            text(row.1 + " ›", 520, y + 6, font(sans, 20), .darkGray)
        }
    }
}
