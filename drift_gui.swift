import Cocoa
import IOKit
import IOKit.hid

// ============ HID-lager ============
let axisNames: [UInt32: String] = [0x30: "X", 0x31: "Y", 0x33: "Rx", 0x34: "Ry"]

final class AxisInfo {
    let lmin: Double, lmax: Double
    init(_ lmin: Double, _ lmax: Double) { self.lmin = lmin; self.lmax = lmax }
    var mid: Double { (lmin + lmax) / 2 }
    var half: Double { max((lmax - lmin) / 2, 1) }
    func norm(_ raw: Double) -> Double { (raw - mid) / half }   // -1..+1, center=0
}

final class Controller {
    let key: String          // serial (BT-MAC) eller "entry:<id>" som fallback
    let name: String
    var latest: [UInt32: Double] = [:]
    var axisInfo: [UInt32: AxisInfo] = [:]
    init(key: String, name: String) { self.key = key; self.name = name }
    var label: String {
        let suffix = key.count >= 5 ? String(key.suffix(5)) : key
        return "\(name) · \(suffix)"
    }
}

var controllers: [Controller] = []          // ordnad efter anslutningsordning
var byKey: [String: Controller] = [:]        // serial -> controller (dedup + listning)
var byEntry: [UInt64: Controller] = [:]      // registry-id -> controller (snabb input-lookup)
var selectedKey: String?
var hidManager: IOHIDManager?                // global så ARC inte river den
var persistMode = false                      // false = fade, true = spara alla prickar

func entryID(_ d: IOHIDDevice) -> UInt64 {
    let s = IOHIDDeviceGetService(d); var id: UInt64 = 0
    if s != 0 { IORegistryEntryGetRegistryEntryID(s, &id) }
    return id
}
func deviceKey(_ d: IOHIDDevice) -> String {
    if let s = IOHIDDeviceGetProperty(d, kIOHIDSerialNumberKey as CFString) as? String, !s.isEmpty { return s }
    return "entry:\(entryID(d))"
}
func deviceName(_ d: IOHIDDevice) -> String {
    (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "Okänd kontroller"
}

let matchCB: IOHIDDeviceCallback = { _, _, _, device in
    let key = deviceKey(device)
    let eid = entryID(device)
    if let existing = byKey[key] {
        byEntry[eid] = existing            // ev. andra representation av samma fysiska enhet
        return
    }
    let c = Controller(key: key, name: deviceName(device))
    controllers.append(c)
    byKey[key] = c
    byEntry[eid] = c
    if selectedKey == nil { selectedKey = key }
}

let removalCB: IOHIDDeviceCallback = { _, _, _, device in
    let key = deviceKey(device)
    byEntry.removeValue(forKey: entryID(device))
    if byEntry.values.contains(where: { $0.key == key }) { return }   // annan representation kvar
    byKey.removeValue(forKey: key)
    controllers.removeAll { $0.key == key }
    if selectedKey == key { selectedKey = controllers.first?.key }
}

let inputCB: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_GenericDesktop) else { return }
    let usage = IOHIDElementGetUsage(element)
    guard axisNames[usage] != nil else { return }
    guard let c = byEntry[entryID(IOHIDElementGetDevice(element))] else { return }
    if c.axisInfo[usage] == nil {
        c.axisInfo[usage] = AxisInfo(Double(IOHIDElementGetLogicalMin(element)),
                                     Double(IOHIDElementGetLogicalMax(element)))
    }
    if let info = c.axisInfo[usage] {
        c.latest[usage] = info.norm(Double(IOHIDValueGetIntegerValue(value)))
    }
}

func startHID() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = manager
    let matches: [[String: Any]] = [
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCB, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCB, nil)
    IOHIDManagerRegisterInputValueCallback(manager, inputCB, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
}

// ============ Ritlager ============
let flipY = true   // negera HID-Y så att "upp på sticken" = "upp på skärmen"

final class StickView: NSView {
    struct Pt { let x: Double; let y: Double; let t: TimeInterval }
    var trailL: [Pt] = []
    var trailR: [Pt] = []
    let windowSec: TimeInterval = 2.5
    var lastKey: String?
    var rowTargets: [(NSRect, String)] = []
    var buttonTargets: [(NSRect, String)] = []
    var toast = ""
    var toastUntil: TimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    private func selected() -> Controller? { selectedKey.flatMap { byKey[$0] } }

    private func append(_ arr: inout [Pt], _ x: Double, _ y: Double, _ now: TimeInterval) {
        if persistMode {
            if let last = arr.last, abs(last.x - x) < 0.003, abs(last.y - y) < 0.003 { return }
            arr.append(Pt(x: x, y: y, t: now))
            if arr.count > 60000 { arr.removeFirst(arr.count - 60000) }
        } else {
            arr.append(Pt(x: x, y: y, t: now))
            arr.removeAll { now - $0.t > windowSec }
        }
    }

    func tick() {
        if selectedKey != lastKey { trailL.removeAll(); trailR.removeAll(); lastKey = selectedKey }
        let now = Date().timeIntervalSinceReferenceDate
        if let c = selected() {
            append(&trailL, c.latest[0x30] ?? 0, c.latest[0x31] ?? 0, now)
            append(&trailR, c.latest[0x33] ?? 0, c.latest[0x34] ?? 0, now)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (rect, action) in buttonTargets where rect.contains(p) { doAction(action); return }
        for (rect, key) in rowTargets where rect.contains(p) {
            selectedKey = key; needsDisplay = true; return
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": doAction("save")
        case "f": doAction("fade")
        case "p": doAction("persist")
        case "c": doAction("clear")
        default: super.keyDown(with: event)
        }
    }

    private func doAction(_ action: String) {
        switch action {
        case "fade": persistMode = false; trailL.removeAll(); trailR.removeAll()
        case "persist": persistMode = true; trailL.removeAll(); trailR.removeAll()
        case "clear": trailL.removeAll(); trailR.removeAll()
        case "save": saveScreenshot()
        default: break
        }
        needsDisplay = true
    }

    private func saveScreenshot() {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var dir = home.appendingPathComponent("Desktop")
        if !fm.fileExists(atPath: dir.path) { dir = home }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = df.string(from: Date())
        let safe = (selected()?.label ?? "kontroller")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "·", with: "-")
        let url = dir.appendingPathComponent("stickdrift-\(safe)-\(stamp).png")
        do {
            try data.write(to: url)
            toast = "💾 Sparad: \(url.path)"
        } catch {
            toast = "⚠️ Kunde inte spara: \(error.localizedDescription)"
        }
        toastUntil = Date().timeIntervalSinceReferenceDate + 5
    }

    private func fillRect(_ r: NSRect, _ c: NSColor) { c.setFill(); NSBezierPath(rect: r).fill() }
    private func text(_ s: String, _ p: NSPoint, _ size: CGFloat, _ c: NSColor) {
        s.draw(at: p, withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
                                       .foregroundColor: c])
    }

    override func draw(_ dirtyRect: NSRect) {
        let H = bounds.height
        fillRect(bounds, NSColor(calibratedWhite: 0.06, alpha: 1))

        text("Lägg kontrollern stilla. Gul box = hur långt sticken vandrat.  🟢 ren · 🟡 liten · 🔴 drift",
             NSPoint(x: 20, y: H - 26), 11, NSColor(calibratedWhite: 0.6, alpha: 1))

        // --- enhetslista ---
        text("Kontroller (\(controllers.count)) — klicka för att välja:", NSPoint(x: 20, y: H - 52), 12, .white)
        rowTargets.removeAll()
        var ry = H - 78
        if controllers.isEmpty {
            text("Ingen ansluten — tryck en knapp på kontrollern.", NSPoint(x: 26, y: ry), 12,
                 NSColor(calibratedWhite: 0.55, alpha: 1))
        }
        for c in controllers {
            let isSel = (c.key == selectedKey)
            let rect = NSRect(x: 20, y: ry - 3, width: 440, height: 24)
            if isSel { fillRect(rect, NSColor(calibratedRed: 0.14, green: 0.30, blue: 0.52, alpha: 1)) }
            text("\(isSel ? "●" : "○") \(c.label)", NSPoint(x: 28, y: ry), 12,
                 isSel ? .white : NSColor(calibratedWhite: 0.72, alpha: 1))
            rowTargets.append((rect, c.key))
            ry -= 28
        }

        // --- knapprad ---
        drawToolbar(y: 405)

        // --- sticks ---
        guard let c = selected() else {
            text("— välj en kontroller ovan —", NSPoint(x: 20, y: 200), 16, NSColor(calibratedWhite: 0.4, alpha: 1))
            drawToast(); return
        }
        let pad: CGFloat = 300, gap: CGFloat = 70
        let startX = (bounds.width - (pad * 2 + gap)) / 2
        let padY: CGFloat = 70
        drawPad(NSRect(x: startX, y: padY, width: pad, height: pad), "Vänster stick", trailL, c.latest, 0x30, 0x31)
        drawPad(NSRect(x: startX + pad + gap, y: padY, width: pad, height: pad), "Höger stick", trailR, c.latest, 0x33, 0x34)
        drawToast()
    }

    private func drawToolbar(y: CGFloat) {
        buttonTargets.removeAll()
        var bx: CGFloat = 20
        func button(_ label: String, _ action: String, _ active: Bool, _ width: CGFloat) {
            let rect = NSRect(x: bx, y: y, width: width, height: 26)
            fillRect(rect, active ? NSColor(calibratedRed: 0.14, green: 0.30, blue: 0.52, alpha: 1)
                                  : NSColor(calibratedWhite: 0.18, alpha: 1))
            NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
            let bp = NSBezierPath(rect: rect); bp.lineWidth = 1; bp.stroke()
            text(label, NSPoint(x: bx + 10, y: y + 6), 12, .white)
            buttonTargets.append((rect, action))
            bx += width + 10
        }
        button("Fade-läge (F)", "fade", !persistMode, 120)
        button("Spara spår (P)", "persist", persistMode, 130)
        button("Rensa (C)", "clear", false, 90)
        button("📷 Spara bild (S)", "save", false, 170)
    }

    private func drawToast() {
        if Date().timeIntervalSinceReferenceDate < toastUntil, !toast.isEmpty {
            text(toast, NSPoint(x: 20, y: 12), 11, .systemGreen)
        }
    }

    private func drawPad(_ rect: NSRect, _ title: String, _ trail: [Pt], _ latest: [UInt32: Double],
                         _ ux: UInt32, _ uy: UInt32) {
        let cx = rect.midX, cy = rect.midY
        let r = rect.width / 2 - 8

        fillRect(rect, NSColor(calibratedWhite: 0.13, alpha: 1))
        NSColor(calibratedWhite: 0.30, alpha: 1).setStroke()
        let border = NSBezierPath(rect: rect); border.lineWidth = 1; border.stroke()

        NSColor(calibratedWhite: 0.24, alpha: 1).setStroke()
        let ch = NSBezierPath()
        ch.move(to: NSPoint(x: rect.minX, y: cy)); ch.line(to: NSPoint(x: rect.maxX, y: cy))
        ch.move(to: NSPoint(x: cx, y: rect.minY)); ch.line(to: NSPoint(x: cx, y: rect.maxY))
        ch.lineWidth = 0.5; ch.stroke()

        let dz: CGFloat = 0.08
        NSColor(calibratedWhite: 0.38, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: cx - r * dz, y: cy - r * dz, width: 2 * r * dz, height: 2 * r * dz))
        ring.lineWidth = 1; ring.stroke()

        func toPx(_ nx: Double, _ ny: Double) -> NSPoint {
            NSPoint(x: cx + CGFloat(nx) * r, y: cy + CGFloat(flipY ? -ny : ny) * r)
        }

        let now = Date().timeIntervalSinceReferenceDate
        var minx = Double.greatestFiniteMagnitude, maxx = -Double.greatestFiniteMagnitude
        var miny = Double.greatestFiniteMagnitude, maxy = -Double.greatestFiniteMagnitude
        for p in trail {
            let alpha: CGFloat = persistMode ? 0.5 : CGFloat(max(0, 1 - (now - p.t) / windowSec)) * 0.5
            NSColor(calibratedRed: 0.4, green: 0.7, blue: 1.0, alpha: alpha).setFill()
            let pt = toPx(p.x, p.y), d: CGFloat = 3
            NSBezierPath(ovalIn: NSRect(x: pt.x - d / 2, y: pt.y - d / 2, width: d, height: d)).fill()
            minx = min(minx, p.x); maxx = max(maxx, p.x); miny = min(miny, p.y); maxy = max(maxy, p.y)
        }

        if !trail.isEmpty {
            let a = toPx(minx, miny), b = toPx(maxx, maxy)
            let box = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                             width: max(abs(b.x - a.x), 1), height: max(abs(b.y - a.y), 1))
            NSColor(calibratedRed: 1, green: 0.8, blue: 0.2, alpha: 0.85).setStroke()
            let bp = NSBezierPath(rect: box); bp.lineWidth = 1.5; bp.stroke()
        }

        let curx = latest[ux] ?? 0, cury = latest[uy] ?? 0
        let offset = (curx * curx + cury * cury).squareRoot()
        let boxSize = trail.isEmpty ? 0 : max(maxx - minx, maxy - miny)
        let verdict: NSColor
        if offset < 0.06 && boxSize < 0.06 { verdict = .systemGreen }
        else if offset < 0.12 { verdict = .systemYellow }
        else { verdict = .systemRed }

        let cur = toPx(curx, cury), dd: CGFloat = 13
        verdict.setFill()
        NSBezierPath(ovalIn: NSRect(x: cur.x - dd / 2, y: cur.y - dd / 2, width: dd, height: dd)).fill()

        text(title, NSPoint(x: rect.minX, y: rect.maxY + 8), 14, .white)
        text(String(format: "x:%+.3f  y:%+.3f", curx, cury), NSPoint(x: rect.minX, y: rect.minY - 24), 12, .white)
        text(String(format: "offset %.1f%%  vandring %.1f%%", offset * 100, boxSize * 50),
             NSPoint(x: rect.minX, y: rect.minY - 44), 12, verdict)
    }
}

// ============ App ============
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate

let view = StickView(frame: NSRect(x: 0, y: 0, width: 780, height: 620))
let window = NSWindow(contentRect: view.frame,
                      styleMask: [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "PowerA Stick Drift"
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)

startHID()

let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in view.tick() }
RunLoop.main.add(timer, forMode: .common)

app.run()
