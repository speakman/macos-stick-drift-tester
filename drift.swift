import Foundation
import IOKit
import IOKit.hid

// Usage: swift drift.swift [probe|rest] [seconds]
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "probe"
let secs = args.count > 2 ? (Double(args[2]) ?? 5.0) : (mode == "rest" ? 5.0 : 1.5)

// Generic Desktop (0x01) analog axis usages we care about for sticks.
let axisNames: [UInt32: String] = [
    0x30: "X  (vänster stick X)",
    0x31: "Y  (vänster stick Y)",
    0x32: "Z  (trigger/extra)",
    0x33: "Rx (höger stick X)",
    0x34: "Ry (höger stick Y)",
    0x35: "Rz (trigger/extra)",
]

final class AxisInfo {
    let usage: UInt32
    let name: String
    let lmin: Double
    let lmax: Double
    init(usage: UInt32, name: String, lmin: Double, lmax: Double) {
        self.usage = usage; self.name = name; self.lmin = lmin; self.lmax = lmax
    }
    var mid: Double { (lmin + lmax) / 2 }
    var half: Double { max((lmax - lmin) / 2, 1) }
    func norm(_ raw: Double) -> Double { (raw - mid) / half }   // -> roughly -1..1, center=0
}

var products: [String] = []
var axisByUsage: [UInt32: AxisInfo] = [:]
var latestRaw: [UInt32: Int] = [:]
var samples: [UInt32: [Double]] = [:]
var fired = false

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Record device product names (does not capture context -> usable as C callback).
let matchCB: IOHIDDeviceCallback = { _, _, _, device in
    let p = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
    products.append(p)
}

// Input values arrive here for every changed element across all matched devices.
let inputCB: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    guard page == UInt32(kHIDPage_GenericDesktop), let name = axisNames[usage] else { return }
    fired = true
    let raw = IOHIDValueGetIntegerValue(value)
    latestRaw[usage] = raw
    if axisByUsage[usage] == nil {
        let lmin = Double(IOHIDElementGetLogicalMin(element))
        let lmax = Double(IOHIDElementGetLogicalMax(element))
        axisByUsage[usage] = AxisInfo(usage: usage, name: name, lmin: lmin, lmax: lmax)
    }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matches: [[String: Any]] = [
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
]
IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCB, nil)
IOHIDManagerRegisterInputValueCallback(manager, inputCB, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openRes != kIOReturnSuccess {
    err(String(format: "IOHIDManagerOpen misslyckades: 0x%08x (kan vara Input Monitoring-behörighet)", openRes))
}

let start = Date()
let warmup = 0.7

if mode == "rest" {
    let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
        if Date().timeIntervalSince(start) < warmup { return }
        for (usage, info) in axisByUsage {
            if let raw = latestRaw[usage] {
                samples[usage, default: []].append(info.norm(Double(raw)))
            }
        }
    }
    RunLoop.current.add(timer, forMode: .default)
    RunLoop.current.run(until: start.addingTimeInterval(warmup + secs))
    timer.invalidate()
} else {
    RunLoop.current.run(until: start.addingTimeInterval(max(secs, 2.5)))
}

// ---- report ----
print("Enheter som matchade: \(products.isEmpty ? "(inga)" : products.joined(separator: ", "))")
if !fired {
    print("⚠️  Inga axel-events togs emot. Kontrollern skickar ingen HID-input till macOS,")
    print("    eller så krävs behörighet. Tryck en knapp/rör en stick och kör igen.")
    exit(fired ? 0 : 2)
}

func fmt(_ d: Double) -> String { String(format: "%+.4f", d) }

if mode == "rest" {
    print("\n=== DRIFT-TEST (\(secs)s i viloläge, normaliserat −1..+1, center=0) ===")
    var jsonAxes: [String] = []
    for usage in axisByUsage.keys.sorted() {
        guard let info = axisByUsage[usage], let vals = samples[usage], !vals.isEmpty else { continue }
        let n = Double(vals.count)
        let mean = vals.reduce(0, +) / n
        let mn = vals.min()!, mx = vals.max()!
        let variance = vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let std = variance.squareRoot()
        let maxAbs = vals.map { abs($0) }.max()!
        let jitter = mx - mn
        let pct = abs(mean) * 100
        let verdict: String
        if abs(mean) < 0.04 && jitter < 0.04 { verdict = "✅ ren (ingen drift)" }
        else if abs(mean) < 0.08 { verdict = "🟡 liten offset (oftast inom deadzone)" }
        else { verdict = "🔴 DRIFT (vilovärde långt från center)" }
        print(String(format: "axis 0x%02X  %-22@", usage, info.name as CVarArg))
        print("   medel=\(fmt(mean))  maxAvvik=\(fmt(maxAbs))  jitter=\(fmt(jitter))  std=\(fmt(std))  (\(vals.count) sampel)")
        print("   rårange=[\(Int(info.lmin))..\(Int(info.lmax))], center=\(Int(info.mid))  →  offset ≈ \(String(format: "%.1f", pct))% av full utböjning")
        print("   \(verdict)\n")
        jsonAxes.append("{\"usage\":\(usage),\"mean\":\(mean),\"maxAbs\":\(maxAbs),\"jitter\":\(jitter),\"std\":\(std)}")
    }
    print("JSON:{\"mode\":\"rest\",\"secs\":\(secs),\"axes\":[\(jsonAxes.joined(separator: ","))]}")
} else {
    print("\n=== PROBE (nuvarande värden) ===")
    for usage in axisByUsage.keys.sorted() {
        guard let info = axisByUsage[usage], let raw = latestRaw[usage] else { continue }
        print(String(format: "axis 0x%02X  %-22@  raw=%d  norm=%@  (range [%d..%d])",
                     usage, info.name as CVarArg, raw, fmt(info.norm(Double(raw))) as CVarArg,
                     Int(info.lmin), Int(info.lmax)))
    }
    print("\nOK — vi kan läsa kontrollern. Kör 'rest' för driftmätning.")
}
