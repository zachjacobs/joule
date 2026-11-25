import SwiftUI
import ServiceManagement
import IOKit.ps

struct Point: Codable, Identifiable {
    var t: Double, input: Double, system: Double, battery: Double, pct: Double
    var plugged: Bool?      // absent in older history files
    var onCharger: Bool { plugged ?? (input > 0.5) }
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
    /// Set for snapshots, which must not touch the saved history.
    var ephemeral = false
    @Published private(set) var status = Status.unknown
    /// How much the battery's one-minute averages have varied lately, in watts.
    @Published private(set) var spread = 0.0
    @Published var appMinutes = 0
    @Published var alerts = AlertSettings.load() { didSet { alerts.store() } }
    private var rules = AlertRules()
    var onNotes: (([Note]) -> Void)?
    private var recent: [(t: Date, battery: Double)] = []
    private var powerEvents: CFRunLoopSource?
    @Published var mode: Int?
    @Published var modeBusy = false
    @Published var visible = false { didSet { if visible != oldValue { schedule() } } }
    @Published var ready = false
    @AppStorage("menuWatts") var menuWatts = true
    var onUpdate: (() -> Void)?

    private let sensors = Sensors(), meter = AppMeter()
    private let queue = DispatchQueue(label: "joule.sampling", qos: .utility)
    private var timer: Timer?
    private var started = Date(), lastTick: Date?, lastLog = Date.distantPast, lastSave = Date(), lastApps = Date.distantPast, lastMode = Date.distantPast
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
        // Plug changes arrive at once, even while sampling slowly in the background.
        let me = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ c in
            guard let c else { return }
            let m = Unmanaged<Model>.fromOpaque(c).takeUnretainedValue()
            m.tick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { m.tick() }
        }, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            powerEvents = src
        }
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: visible ? 1 : 5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = visible ? 0.1 : 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if visible { tick() }
    }

    /// Swaps in a sample scene and forgets everything measured so far.
    func stage(_ s: Demo.Scene) {
        ephemeral = true
        adjust = { Demo.fill(&$0, s) }
        queue.sync {}
        DispatchQueue.main.async { [self] in
            lastTick = nil; now = Reading(); smooth = Reading(); bucket = []; status = .unknown
            history = Demo.history(s); apps = Demo.apps; appMinutes = 60; mode = s.mode
            tick()
        }
    }

    func tick() {
        let wantApps = Date().timeIntervalSince(lastApps) >= (visible ? 3 : 30)
        if wantApps { lastApps = Date() }
        if visible, Date().timeIntervalSince(lastMode) > 10 { lastMode = Date(); readMode() }
        queue.async { [self] in
            guard var r = sensors.read() else { return }
            adjust?(&r)
            let reading = r
            let a = wantApps && adjust == nil ? meter.sample() : nil
            let mins = Int(meter.covered / 60)
            DispatchQueue.main.async {
                if wantApps, self.adjust == nil { self.appMinutes = mins }
                self.apply(reading, a)
            }
        }
    }

    private func apply(_ r: Reading, _ a: [AppUsage]?) {
        let dt = lastTick.map { r.date.timeIntervalSince($0) } ?? .infinity
        // A plug change or a wake from sleep invalidates the running averages.
        if dt > 60 || r.plugged != now.plugged {
            sustained = r.battery; load = r.system; started = r.date; recent = []
            if dt.isInfinite { resume(r) }
        } else {
            let age = r.date.timeIntervalSince(started)
            let k = 1 - exp(-dt / min(180, max(5, age)))
            sustained += (r.battery - sustained) * k
            load += (r.system - load) * k
        }
        recent.append((r.date, r.battery))
        recent.removeAll { r.date.timeIntervalSince($0.t) > 360 }
        spread = Model.spread(recent.map { ($0.t.timeIntervalSince1970, $0.battery) })
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
        ready = r.date.timeIntervalSince(started) > 20
        // Keep plugged-in and unplugged history apart, so neither is averaged into the other.
        if dt.isFinite, r.plugged != now.plugged {
            commit(r.date)
            lastMode = .distantPast   // macOS keeps a separate energy mode for each power source.
        }
        now = r
        status = Model.settle(status, r, sustained, ready)
        if let a, !a.isEmpty {
            var next: [String: Double] = [:]
            let smoothed = a.prefix(12).map { u -> AppUsage in
                var u = u
                u.watts = appAverage[u.id].map { $0 * 0.6 + u.watts * 0.4 } ?? u.watts
                next[u.id] = u.watts
                return u
            }
            appAverage = next
            apps = Array(smoothed.prefix(5))
        }
        // The charger reads zero for a moment while it negotiates.
        if !(r.plugged && r.input < 0.5) { bucket.append(r) }
        if r.date.timeIntervalSince(lastLog) >= 20 { commit(r.date) }
        let left = toEmpty ?? (r.plugged ? nil : ifUnplugged)
        let notes = rules.step(r.date, plugged: r.plugged, percent: r.percent, status: status, deficit: -sustained, adapter: r.adapterWatts, left: ready ? left.map(soft) : nil, alerts)
        if !notes.isEmpty { onNotes?(notes) }
        onUpdate?()
    }

    private func commit(_ t: Date) {
        lastLog = t
        guard let end = bucket.last else { return }
        let n = Double(bucket.count)
        func avg(_ k: KeyPath<Reading, Double>) -> Double { bucket.reduce(0) { $0 + $1[keyPath: k] } / n }
        history.append(Point(t: end.date.timeIntervalSince1970, input: avg(\.input), system: avg(\.system), battery: avg(\.battery), pct: end.percent, plugged: end.plugged))
        history.removeAll { $0.t < t.timeIntervalSince1970 - 86400 }
        bucket = []
        if t.timeIntervalSince(lastSave) >= 60 { lastSave = t; save() }
    }

    /// Picks the averages back up from saved history after a quick relaunch.
    private func resume(_ r: Reading) {
        let from = r.date.timeIntervalSince1970
        let pts = history.suffix(9).filter { from - $0.t < 300 && $0.onCharger == r.plugged }
        guard pts.count >= 4, let last = pts.last, from - last.t < 90 else { return }
        let n = Double(pts.count)
        sustained = pts.reduce(0) { $0 + $1.battery } / n
        load = pts.reduce(0) { $0 + $1.system } / n
        started = r.date.addingTimeInterval(-n * 20)
        recent = pts.map { ($0.date, $0.battery) }
    }

    /// Standard deviation of one-minute means: how far the next few minutes may stray.
    static func spread(_ p: [(Double, Double)]) -> Double {
        guard let end = p.last?.0 else { return 0 }
        var blocks: [Int: (Double, Double)] = [:]
        for (t, v) in p { let b = blocks[Int((end - t) / 60)] ?? (0, 0); blocks[Int((end - t) / 60)] = (b.0 + v, b.1 + 1) }
        let m = blocks.values.map { $0.0 / $0.1 }
        guard m.count >= 3 else { return 0 }
        let mean = m.reduce(0, +) / Double(m.count)
        return sqrt(m.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(m.count - 1))
    }

    /// Changing state takes a clear swing; staying in it takes less. Stops the headline flickering.
    static func settle(_ was: Status, _ r: Reading, _ s: Double, _ ready: Bool) -> Status {
        if r.fullCap == 0 { return .unknown }
        if !r.plugged { return .battery }
        if !ready { return r.full ? .full : .held }
        if s < -1 || (was == .draining && s < -0.1) { return .draining }
        if r.full { return .full }
        if s > 0.8 || (was == .charging && s > 0.1) { return .charging }
        return .held
    }

    func save() {
        guard adjust == nil, !ephemeral else { return }
        let h = history, f = file
        queue.async { if let d = try? JSONEncoder().encode(h) { try? d.write(to: f, options: .atomic) } }
    }
    func flush() { save(); queue.sync {} }

    // MARK: Meaning

    var headline: String {
        if !ready && now.plugged && now.fullCap > 0 && !now.full { return "Plugged in" }
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
            return "Lately using \(W(max(0.1, -sustained))) more than the charger can supply."
        case .charging:
            guard let h = toFull else { return "Barely gaining charge." }
            if uneven { return "Full in \(fullText), depending on load." }
            if h >= 24 { return "Barely gaining. Full in over a day at this rate." }
            return "Full in \(soft(h)), around \(clock(h))"
        case .held: return "The charger is covering your Mac; the battery is idle."
        case .full: return "Running from the charger."
        case .battery:
            guard let h = toEmpty else { return "Barely drawing power." }
            if uneven { return "\(emptyText) left, depending on load." }
            if h >= 24 { return "Over a day left." }
            return "\(soft(h)) left, until around \(clock(h))"
        case .unknown: return ""
        }
    }

    /// True when the recent swing is big enough that one exact time would be false precision.
    var uneven: Bool { spread > max(0.8, abs(sustained) * 0.3) }
    private func chargeTime(_ to: Double, _ w: Double) -> Double? { Estimate.hoursToCharge(from: now.soc, to: to, watts: w, capacityWh: now.fullWh) }
    private func drainTime(_ w: Double) -> Double? { w > 0.3 ? now.remainingWh / w : nil }
    var toFull: Double? { chargeTime(1, sustained) }
    var to80: Double? { chargeTime(0.8, sustained) }
    var toEmpty: Double? { drainTime(-sustained) }
    var ifUnplugged: Double? { drainTime(load) }
    var fullText: String { between(chargeTime(1, sustained + spread), toFull, chargeTime(1, sustained - spread)) }
    var emptyText: String { between(drainTime(-sustained + spread), toEmpty, drainTime(-sustained - spread)) }

    /// A single time when the load is steady, otherwise a range. `slow` is nil when it might never get there.
    private func between(_ quick: Double?, _ mid: Double?, _ slow: Double?) -> String {
        guard let mid else { return "–" }
        guard uneven, let quick else { return soft(mid) }
        if quick >= 24 { return "Over a day" }
        guard let slow, slow < 24 else { return "\(brief(quick))+" }
        if slow / max(0.01, quick) < 1.2 { return soft(mid) }
        let a = brief(quick), b = brief(slow)
        if a == b { return a }
        return a.last == b.last ? "\(a.dropLast())–\(b)" : "\(a)–\(b)"
    }

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
        guard adjust == nil else { return }
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
/// Coarser as it gets longer, so the last digits don't twitch.
func soft(_ h: Double) -> String {
    let m = h * 60, step = m >= 180 ? 10.0 : m >= 45 ? 5 : 1
    return span((m / step).rounded() * step / 60)
}
func brief(_ h: Double) -> String {
    if h < 0.95 { let m = h * 60, s = m >= 20 ? 5.0 : 1; return "\(Int(max(1, (m / s).rounded() * s)))m" }
    let r = h < 10 ? (h * 2).rounded() / 2 : h.rounded()
    return r == r.rounded() ? "\(Int(r))h" : String(format: "%.1fh", r)
}
func clock(_ h: Double) -> String {
    let grain = h > 0.75 ? 300.0 : 60
    let d = Date(timeIntervalSince1970: ((Date().timeIntervalSince1970 + h * 3600) / grain).rounded() * grain)
    let t = d.formatted(date: .omitted, time: .shortened)
    return Calendar.current.isDateInToday(d) ? t : "\(t) \(d.formatted(.dateTime.weekday(.abbreviated)))"
}
