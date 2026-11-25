import Foundation
import IOKit

/// Read-only access to the System Management Controller's live sensors (no root needed).
final class SMC {
    private var conn: io_connect_t = 0
    private var ok = false
    private var sizes: [String: (UInt8, String)] = [:]

    init() {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard s != 0 else { return }
        ok = IOServiceOpen(s, mach_task_self_, 0, &conn) == KERN_SUCCESS
        IOObjectRelease(s)
    }
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 80)
        var n = 80
        guard ok, IOConnectCallStructMethod(conn, 2, input, 80, &out, &n) == KERN_SUCCESS, out[40] == 0 else { return nil }
        return out
    }
    private func raw(_ key: String) -> (String, [UInt8])? {
        var i = [UInt8](repeating: 0, count: 80)
        let c = Array(key.utf8)
        guard c.count == 4 else { return nil }
        for j in 0..<4 { i[j] = c[3 - j] }
        if sizes[key] == nil {
            i[42] = 9
            guard let o = call(i) else { return nil }
            sizes[key] = (o[28], String(bytes: o[32..<36].reversed(), encoding: .ascii) ?? "")
        }
        guard let (size, type) = sizes[key], size <= 32 else { return nil }
        i[28] = size; i[42] = 5
        guard let v = call(i) else { return nil }
        return (type, Array(v[48..<48 + Int(size)]))
    }
    func value(_ key: String) -> Double? {
        guard let (type, b) = raw(key) else { return nil }
        switch type {
        case "flt " where b.count == 4:
            let f = Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            return f.isFinite ? f : nil
        case "si16" where b.count == 2: return Double(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8))
        case "ui16" where b.count == 2: return Double(UInt16(b[0]) | UInt16(b[1]) << 8)
        default: return nil
        }
    }
}

struct Profile: Hashable { var volts: Double; var amps: Double; var watts: Double { volts * amps } }

struct Reading {
    var date = Date()
    var percent = 0.0
    var plugged = false
    var charging = false
    var full = false
    /// Watts. Battery is signed: positive flows in, negative flows out.
    var input = 0.0, battery = 0.0, system = 0.0, wall = 0.0
    var display: Double?, processor: Double?
    var adapterWatts = 0.0, inVolts = 0.0, inAmps = 0.0
    var contract: Profile?
    var profiles: [Profile] = []
    var volts = 0.0, amps = 0.0
    var remaining = 0.0, fullCap = 0.0, nominal = 0.0, design = 0.0   // mAh
    var cycles = 0, ratedCycles = 1000
    var temperature: Double?
    var live = false

    static let nominalVolts = 11.55
    var fullWh: Double { fullCap * Reading.nominalVolts / 1000 }
    var remainingWh: Double { remaining * Reading.nominalVolts / 1000 }
    var health: Double { design > 0 ? min(1, nominal / design) : 0 }
    var soc: Double { fullCap > 0 ? min(1, remaining / fullCap) : 0 }
}

final class Sensors {
    private let smc = SMC()

    private func signed(_ v: Any?) -> Double {
        guard let n = v as? NSNumber else { return 0 }
        return Double(n.int64Value)
    }

    func read() -> Reading? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var ref: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = ref?.takeRetainedValue() as? [String: Any] else { return nil }
        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        let pt = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        let ad = d["AdapterDetails"] as? [String: Any] ?? [:]
        func num(_ a: String) -> Double { signed(d[a] ?? bd[a]) }

        var r = Reading()
        r.percent = num("CurrentCapacity")
        r.plugged = d["ExternalConnected"] as? Bool ?? false
        r.charging = d["IsCharging"] as? Bool ?? false
        r.full = d["FullyCharged"] as? Bool ?? false
        r.remaining = num("AppleRawCurrentCapacity")
        r.fullCap = num("AppleRawMaxCapacity")
        r.nominal = num("NominalChargeCapacity")
        r.design = num("DesignCapacity")
        r.cycles = Int(num("CycleCount"))
        if num("DesignCycleCount9C") > 0 { r.ratedCycles = Int(num("DesignCycleCount9C")) }

        let v = smc.value("B0AV") ?? num("Voltage")
        let a = smc.value("B0AC") ?? num("InstantAmperage")
        r.live = smc.value("PDTR") != nil && smc.value("B0AC") != nil
        r.volts = v / 1000; r.amps = a / 1000
        let temps = ["TB0T", "TB1T", "TB2T"].compactMap { smc.value($0) }.filter { $0 > 0 && $0 < 100 }
        r.temperature = temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)

        if r.live {
            r.input = r.plugged ? max(0, smc.value("PDTR") ?? 0) : 0
            r.battery = r.volts * r.amps
            r.inVolts = smc.value("VD0R") ?? 0
            r.inAmps = smc.value("ID0R") ?? 0
        } else {
            r.input = r.plugged ? signed(pt["SystemPowerIn"]) / 1000 : 0
            r.battery = r.input - signed(pt["SystemLoad"]) / 1000
            r.inVolts = signed(pt["SystemVoltageIn"]) / 1000
            r.inAmps = signed(pt["SystemCurrentIn"]) / 1000
        }
        // Energy balance: whatever the charger supplies that the battery doesn't take, the Mac uses.
        r.system = max(0, r.input - r.battery)
        let loss = min(max(0, signed(pt["AdapterEfficiencyLoss"]) / 1000), r.input * 0.25)
        r.wall = r.plugged && r.input > 0 ? r.input + loss : 0
        // Component keys are undocumented, so only show them while they fit inside the measured total.
        if let p = smc.value("PDBR"), let c = smc.value("PHPC"), p >= 0, c >= 0 {
            r.display = min(p, r.system)
            r.processor = min(c, max(0, r.system - p))
        }
        if r.plugged {
            r.adapterWatts = signed(ad["Watts"])
            let cv = signed(ad["AdapterVoltage"]) / 1000, ca = signed(ad["Current"]) / 1000
            if cv > 0 { r.contract = Profile(volts: cv, amps: ca) }
            r.profiles = (ad["UsbHvcMenu"] as? [[String: Any]] ?? []).map {
                Profile(volts: signed($0["MaxVoltage"]) / 1000, amps: signed($0["MaxCurrent"]) / 1000)
            }
        }
        return r
    }
}

enum Estimate {
    /// Hours to move the cell between two charge fractions at `watts` net. Charging slows near full,
    /// so each slice is capped by what a lithium cell will accept at that level.
    static func hoursToCharge(from: Double, to: Double, watts: Double, capacityWh: Double) -> Double? {
        guard watts > 0.4, capacityWh > 0 else { return nil }
        guard to > from else { return 0 }
        let n = 60, step = (to - from) / Double(n)
        var t = 0.0
        for i in 0..<n {
            let s = from + (Double(i) + 0.5) * step
            let c = s < 0.5 ? 1.0 : s < 0.8 ? 1.0 - (s - 0.5) * 1.5 : max(0.06, 0.55 - (s - 0.8) * 2.45)
            t += step * capacityWh / min(watts, c * capacityWh)
        }
        return t
    }
}

struct AppUsage: Identifiable {
    var id: String { name }
    var name: String
    var icon: String?      // path to an app bundle
    var symbol: String     // used when there is no bundle
    var watts = 0.0        // since the last sample
    var hour = 0.0         // average over the last hour
}

/// Measures per-app processor energy from the kernel's own counters, and keeps an hour of it.
final class AppMeter {
    private var last: [pid_t: (start: UInt64, nj: UInt64)] = [:]
    private var lastTime: UInt64 = 0, lastAbs: UInt64 = 0
    private var minutes: [(minute: UInt64, seconds: Double, joules: [String: Double])] = []
    private var known: [String: AppUsage] = [:]
    /// Seconds of measurement behind the hourly averages.
    var covered: Double { minutes.reduce(0) { $0 + $1.seconds } }

    /// Turns an executable path into something a person would recognise.
    static func identify(_ path: String) -> AppUsage {
        func has(_ p: String) -> Bool { path.hasPrefix(p) }
        if path.contains("com.apple.WebKit") { return AppUsage(name: "Safari and web views", icon: "/Applications/Safari.app", symbol: "safari") }
        if path.contains("/System/Applications/") || !has("/System/"), let e = path.range(of: ".app/") {
            let app = String(path[..<e.lowerBound]) + ".app"
            return AppUsage(name: ((app as NSString).lastPathComponent as NSString).deletingPathExtension, icon: app, symbol: "app")
        }
        if has("/System/") || has("/usr/libexec/") || has("/usr/sbin/") || has("/sbin/") || has("/Library/Apple/") {
            return AppUsage(name: "macOS", icon: nil, symbol: "apple.logo")
        }
        if has("/usr/") || has("/bin/") || has("/opt/") || has("/Library/Developer/") {
            return AppUsage(name: "Command line tools", icon: nil, symbol: "terminal.fill")
        }
        return AppUsage(name: (path as NSString).lastPathComponent, icon: nil, symbol: "gearshape.fill")
    }

    func sample() -> [AppUsage] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), abs = mach_absolute_time()
        let dt = Double(now - lastTime) / 1e9
        let fresh = lastTime == 0 || dt > 300
        let since = lastAbs
        lastTime = now; lastAbs = abs
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var next: [pid_t: (start: UInt64, nj: UInt64)] = [:]
        var joules: [String: Double] = [:]
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var ri = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard rc == 0 else { continue }
            next[pid] = (ri.ri_proc_start_abstime, ri.ri_energy_nj)
            guard !fresh else { continue }
            let before: UInt64
            if let p = last[pid], p.start == ri.ri_proc_start_abstime { before = p.nj }
            else if ri.ri_proc_start_abstime >= since { before = 0 }   // Started since the last sample.
            else { continue }
            guard ri.ri_energy_nj > before else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, 4096) > 0 else { continue }
            let who = AppMeter.identify(String(cString: buf))
            // Helpers often run from outside their app bundle, so group by name and keep any icon found.
            if known[who.name]?.icon == nil { known[who.name] = who }
            joules[who.name, default: 0] += Double(ri.ri_energy_nj - before) / 1e9
        }
        last = next
        guard !fresh, dt > 0 else { return [] }
        let minute = now / 60_000_000_000
        if minutes.last?.minute != minute { minutes.append((minute, 0, [:])) }
        minutes[minutes.count - 1].seconds += dt
        for (k, j) in joules { minutes[minutes.count - 1].joules[k, default: 0] += j }
        minutes.removeAll { $0.minute + 60 <= minute }
        let total = max(1, covered)
        var hour: [String: Double] = [:]
        for m in minutes { for (k, j) in m.joules { hour[k, default: 0] += j } }
        return hour.compactMap { name, j in
            guard var u = known[name] else { return nil }
            u.watts = (joules[name] ?? 0) / dt
            u.hour = j / total
            return u
        }.sorted { $0.hour > $1.hour }
    }
}
