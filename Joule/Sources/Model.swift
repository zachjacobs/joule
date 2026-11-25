import SwiftUI
import ServiceManagement

struct Point: Codable, Identifiable {
    var t: Double, input: Double, system: Double, battery: Double, pct: Double
    var id: Double { t }
    var date: Date { Date(timeIntervalSince1970: t) }
}

final class PowerLog: ObservableObject { @Published var points: [Point] = [] }

enum Status { case draining, charging, held, full, battery, unknown }

final class Model: ObservableObject {
    @Published var now = Reading()
    /// ~8 s average, so the picture drifts instead of jumping.
    @Published var smooth = Reading()
    @Published var sustained = 0.0          // battery watts, ~3 min average
    @Published var load = 0.0               // Mac watts, ~3 min average
    @Published var apps: [AppUsage] = []
    /// Kept apart so the chart redraws when a point lands, not every second.
    let log = PowerLog()
    var history: [Point] { get { log.points } set { log.points = newValue } }
    var adjust: ((inout Reading) -> Void)?
    @Published var mode: Int?
    @Published var modeBusy = false
    @Published var visible = false { didSet { if visible != oldValue { schedule() } } }
    @Published var ready = false
    @AppStorage("menuWatts") var menuWatts = true
    var onUpdate: (() -> Void)?

    private let sensors = Sensors(), meter = AppMeter()
    private let queue = DispatchQueue(label: "joule.sampling", qos: .utility)
    private var timer: Timer?
    private var started = Date(), lastTick: Date?, lastLog = Date.distantPast, lastApps = Date.distantPast, lastMode = Date.distantPast
    private var bucket: [Reading] = []
    private var appAverage: [String: Double] = [:]

    private let file: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Joule")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("history.json")
    }()

    init() {
        if let d = try? Data(contentsOf: file), let h = try? JSONDecoder().decode([Point].self, from: d) {
            history = h.filter { $0.t > Date().timeIntervalSince1970 - 86400 }
        }
        tick(); schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: visible ? 1 : 5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = visible ? 0.1 : 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if visible { tick() }
    }

    func tick() {
        let wantApps = visible && Date().timeIntervalSince(lastApps) >= 3
        if wantApps { lastApps = Date() }
        if visible, Date().timeIntervalSince(lastMode) > 10 { lastMode = Date(); readMode() }
        queue.async { [self] in
            guard var r = sensors.read() else { return }
            adjust?(&r)
            let reading = r
            let a = wantApps ? meter.sample() : nil
            DispatchQueue.main.async { self.apply(reading, a) }
        }
    }

    private func apply(_ r: Reading, _ a: [AppUsage]?) {
        let dt = lastTick.map { r.date.timeIntervalSince($0) } ?? .infinity
        // A plug change or a wake from sleep invalidates the running averages.
        if dt > 60 || r.plugged != now.plugged {
            sustained = r.battery; load = r.system; started = r.date
        } else {
            let age = r.date.timeIntervalSince(started)
            let k = 1 - exp(-dt / min(180, max(5, age)))
            sustained += (r.battery - sustained) * k
            load += (r.system - load) * k
        }
        var f = r
        if dt <= 60, r.plugged == now.plugged {
            // Catch up quickly after a plug change, while the charger is still negotiating.
            let k = 1 - exp(-dt / min(8, max(1.5, r.date.timeIntervalSince(started) / 2)))
            func ease(_ p: WritableKeyPath<Reading, Double>) { f[keyPath: p] = smooth[keyPath: p] + (r[keyPath: p] - smooth[keyPath: p]) * k }
            [\Reading.input, \.battery, \.system, \.wall].forEach(ease)
            if let a = smooth.display, let b = r.display { f.display = a + (b - a) * k }
            if let a = smooth.processor, let b = r.processor { f.processor = a + (b - a) * k }
        }
        smooth = f
        lastTick = r.date
        ready = r.date.timeIntervalSince(started) > 15
        now = r
        if let a, !a.isEmpty {
            var next: [String: Double] = [:]
            let smoothed = a.map { u -> AppUsage in
                var u = u
                u.watts = appAverage[u.id].map { $0 * 0.6 + u.watts * 0.4 } ?? u.watts
                next[u.id] = u.watts
                return u
            }
            appAverage = next
            apps = Array(smoothed.sorted { $0.watts > $1.watts }.prefix(5))
        }
        bucket.append(r)
        if r.date.timeIntervalSince(lastLog) >= 20 {
            lastLog = r.date
            let n = Double(bucket.count)
            func avg(_ k: KeyPath<Reading, Double>) -> Double { bucket.reduce(0) { $0 + $1[keyPath: k] } / n }
            history.append(Point(t: r.date.timeIntervalSince1970, input: avg(\.input), system: avg(\.system), battery: avg(\.battery), pct: r.percent))
            history.removeAll { $0.t < r.date.timeIntervalSince1970 - 86400 }
            bucket = []
            if history.count % 6 == 0 { save() }
        }
        onUpdate?()
    }

    func save() {
        guard adjust == nil else { return }
        let h = history, f = file
        queue.async { if let d = try? JSONEncoder().encode(h) { try? d.write(to: f, options: .atomic) } }
    }
    func flush() { save(); queue.sync {} }

    // MARK: Meaning

    var status: Status {
        if now.fullCap == 0 { return .unknown }
        if !now.plugged { return .battery }
        if ready && sustained < -0.8 { return .draining }
        if now.full { return .full }
        if sustained > 0.4 { return .charging }
        return .held
    }
    var headline: String {
        if !ready && now.plugged && now.fullCap > 0 { return "Plugged in" }
        switch status {
        case .draining: return "Plugged in, but draining"
        case .charging: return sustained < 15 && now.percent < 80 ? "Charging slowly" : "Charging"
        case .held: return "Holding steady"
        case .full: return "Fully charged"
        case .battery: return now.percent <= 20 ? "Low battery" : "On battery"
        case .unknown: return "Reading sensors"
        }
    }
    var detail: String {
        guard ready else { return "Measuring power flow…" }
        switch status {
        case .draining:
            return "On average your Mac needs \(W(-sustained)) more than the charger supplies."
        case .charging:
            guard let h = toFull else { return "Charging" }
            return h >= 24 ? "Barely gaining. Full in over a day at this rate." : "Full in \(span(h)), around \(clock(h))"
        case .held: return "The charger is covering your Mac; the battery is idle."
        case .full: return "Running from the charger."
        case .battery:
            guard let h = toEmpty else { return "Barely drawing power." }
            return h >= 24 ? "Over a day left." : "\(span(h)) left, until around \(clock(h))"
        case .unknown: return ""
        }
    }
    var toFull: Double? { Estimate.hoursToCharge(from: now.soc, to: 1, watts: sustained, capacityWh: now.fullWh) }
    var to80: Double? { Estimate.hoursToCharge(from: now.soc, to: 0.8, watts: sustained, capacityWh: now.fullWh) }
    var toEmpty: Double? { sustained < -0.3 ? now.remainingWh / -sustained : nil }
    var ifUnplugged: Double? { load > 0.3 ? now.remainingWh / load : nil }

    func withCharger(_ w: Double) -> Double? {
        Estimate.hoursToCharge(from: now.soc, to: 1, watts: w * 0.955 - load, capacityWh: now.fullWh)
    }

    // MARK: Energy mode

    private static func run(_ path: String, _ args: [String], _ done: @escaping (String, Bool) -> Void) {
        DispatchQueue.global().async {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return DispatchQueue.main.async { done("", false) } }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { done(String(decoding: d, as: UTF8.self), ok) }
        }
    }
    func readMode() {
        Model.run("/usr/bin/pmset", ["-g"]) { out, _ in
            for l in out.split(separator: "\n") {
                let p = l.split(separator: " ")
                if p.count >= 2, p[0] == "powermode" { self.mode = Int(p[1]) }
            }
        }
    }
    /// macOS requires an administrator to change this, so the system shows its own prompt.
    func setMode(_ m: Int) {
        guard (0...2).contains(m), m != mode, !modeBusy else { return }
        modeBusy = true
        let cmd = "/usr/bin/pmset \(now.plugged ? "-c" : "-b") powermode \(m)"
        Model.run("/usr/bin/osascript", ["-e", "do shell script \"\(cmd)\" with administrator privileges"]) { _, _ in
            self.modeBusy = false
            self.readMode()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

func W(_ v: Double) -> String { String(format: "%.1f W", v) }
func span(_ h: Double) -> String {
    let m = Int((h * 60).rounded())
    if m >= 60 * 24 { return "Over a day" }
    return m < 60 ? "\(max(1, m))m" : "\(m / 60)h \(String(format: "%02d", m % 60))m"
}
func clock(_ h: Double) -> String {
    let d = Date().addingTimeInterval(h * 3600)
    let t = d.formatted(date: .omitted, time: .shortened)
    return Calendar.current.isDateInToday(d) ? t : "\(t) \(d.formatted(.dateTime.weekday(.abbreviated)))"
}
