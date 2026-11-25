import Foundation

/// Made-up data and checks, used only by the development flags.
enum Demo {
    /// Sample machines for screenshots, so none of them show the developer's own Mac.
    struct Scene {
        var percent: Double, input: Double, system: Double, display: Double, processor: Double
        var adapter = 0.0, volts = 0.0, profiles: [Profile] = []
        var mode = 0, wobble = 3.0, past = Past.charger
        var full = false
        enum Past { case charger, busy, unplugged, day }
        var battery: Double { input - system }
        var plugged: Bool { adapter > 0 }
    }
    private static let big = [Profile(volts: 5, amps: 3), Profile(volts: 9, amps: 3), Profile(volts: 15, amps: 3), Profile(volts: 20, amps: 3.5)]
    static let scenes: [String: Scene] = [
        "charging": Scene(percent: 42, input: 64.2, system: 15.8, display: 5.4, processor: 5.9, adapter: 70, volts: 20, profiles: big),
        "draining": Scene(percent: 18, input: 25.8, system: 37.4, display: 7.6, processor: 18.2, adapter: 27, volts: 9, profiles: Array(big.prefix(2)), wobble: 4, past: .busy),
        "battery": Scene(percent: 64, input: 0, system: 9.8, display: 3.9, processor: 2.8, mode: 1, wobble: 1.5, past: .unplugged),
        "full": Scene(percent: 100, input: 17.4, system: 17.4, display: 6.1, processor: 6.4, adapter: 96, volts: 20, profiles: big, mode: 2, past: .day, full: true),
    ]

    static func fill(_ r: inout Reading, _ s: Scene) {
        r.percent = s.percent; r.plugged = s.plugged; r.charging = s.battery > 0.5; r.full = s.full
        r.input = s.input; r.system = s.system; r.battery = s.battery
        r.display = s.display; r.processor = s.processor
        r.wall = s.plugged ? s.input * 1.045 : 0
        r.adapterWatts = s.adapter; r.profiles = s.profiles
        r.contract = s.plugged ? Profile(volts: s.volts, amps: (s.adapter / s.volts * 10).rounded() / 10) : nil
        r.inVolts = s.plugged ? s.volts * 0.985 : 0; r.inAmps = s.plugged ? s.input / r.inVolts : 0
        r.fullCap = 5960; r.nominal = 6010; r.design = 6249; r.cycles = 112; r.ratedCycles = 1000
        r.remaining = r.fullCap * s.percent / 100
        r.volts = 10.9 + s.percent / 100 * 1.7; r.amps = s.battery / r.volts
        r.temperature = 31
    }

    static let apps: [AppUsage] = [
        AppUsage(name: "Safari", icon: "/Applications/Safari.app", symbol: "safari", watts: 0.62, hour: 0.74),
        AppUsage(name: "macOS", icon: nil, symbol: "apple.logo", watts: 0.31, hour: 0.38),
        AppUsage(name: "Music", icon: "/System/Applications/Music.app", symbol: "app", watts: 0.16, hour: 0.14),
        AppUsage(name: "Messages", icon: "/System/Applications/Messages.app", symbol: "app", watts: 0.021, hour: 0.062),
        AppUsage(name: "Notes", icon: "/System/Applications/Notes.app", symbol: "app", watts: 0.004, hour: 0.035),
    ]

    /// Power history that ends at the scene's present values, with the level worked out backwards from them.
    static func history(_ s: Scene) -> [Point] {
        let now = Date().timeIntervalSince1970
        var out: [Point] = []
        var t = now - 86400, seed = UInt64(7)
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) * 2 - 1 }
        while t < now {
            let age = (now - t) / 60
            let wave = (sin(age / 3.1) * 0.7 + sin(age / 1.3) * 0.4 + random() * 0.4) * s.wobble * min(1, age / 5)
            var plugged = s.plugged, input = s.input, load = s.system, skip = false
            switch s.past {
            case .charger:
                if age > 16, age < 34 { plugged = false }
                if age >= 34 { load = 24; input = 64.2 }
            case .busy:
                if age > 24 { load = 21 }
                if age > 12, age <= 24 { load = 29 }
                if age > 44, age < 49 { skip = true }
            case .unplugged:
                if age > 26 { plugged = true; input = 25.8; load = 17 }
            case .day:
                if age > 470, age < 920 { skip = true }
                if age > 150, age < 420 { plugged = false; load = 10 }
                if age > 920, age < 1180 { plugged = false; load = 9 }
                if age > 60, age <= 150 { input = 58 }
                if age <= 60 || (age >= 420 && age <= 470) || age >= 1180 { input = load }
            }
            let system = max(4, load + (s.full && input == load ? 0 : wave))
            if !skip { out.append(Point(t: t, input: plugged ? input : 0, system: system, battery: (plugged ? input : 0) - system, pct: 0, plugged: plugged)) }
            t += 20
        }
        var pct = s.percent
        for i in out.indices.reversed() {
            out[i].pct = min(100, max(3, pct))
            pct -= out[i].battery * 20 / 3600 / 68.8 * 100
            if s.full && pct > 100 { pct = 100 }
        }
        return out
    }

    static func selfTest() -> Bool {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1 }; print(ok ? "ok  " : "FAIL", what) }
        let t0 = Calendar.current.startOfDay(for: Date()).addingTimeInterval(36000)
        let s = AlertSettings()
        func run(_ r: inout AlertRules, _ at: Double, _ plugged: Bool, _ pct: Double, _ st: Status, _ set: AlertSettings? = nil) -> [String] {
            r.step(t0.addingTimeInterval(at), plugged: plugged, percent: pct, status: st, deficit: 4, adapter: 27, left: "48m", set ?? s).map(\.id)
        }
        var r = AlertRules()
        check(run(&r, 0, true, 90, .charging).isEmpty, "launch above both thresholds is silent")
        r = AlertRules(); check(run(&r, 0, false, 9, .battery).isEmpty, "launch already low is silent")
        r = AlertRules(); _ = run(&r, 0, true, 50, .draining)
        check(run(&r, 170, true, 50, .draining).isEmpty, "draining under 3 minutes is silent")
        check(run(&r, 185, true, 50, .draining) == ["draining"], "draining 3 minutes alerts")
        check(run(&r, 400, true, 50, .draining).isEmpty, "draining does not repeat")
        check(run(&r, 3900, true, 50, .draining) == ["draining"], "draining repeats after an hour")
        r = AlertRules(); _ = run(&r, 0, true, 50, .draining); _ = run(&r, 100, true, 50, .held); _ = run(&r, 110, true, 50, .draining)
        check(run(&r, 200, true, 50, .draining).isEmpty, "recovering restarts the 3 minutes")
        r = AlertRules(); _ = run(&r, 0, true, 50, .charging); _ = run(&r, 10, false, 50, .battery)
        check(run(&r, 17, true, 50, .held) == ["drop"], "7 second dropout alerts")
        _ = run(&r, 30, false, 50, .battery)
        let n = r.step(t0.addingTimeInterval(39), plugged: true, percent: 50, status: .held, deficit: 0, adapter: 27, left: nil, s)
        check(n.first?.title == "Charger dropped out for 9 seconds" && n.first?.body.hasPrefix("That's 2 times today") == true, "second dropout is counted")
        _ = run(&r, 100, false, 50, .battery)
        check(run(&r, 160, true, 50, .held).isEmpty, "a real unplug is silent")
        r = AlertRules(); _ = run(&r, 0, true, 79, .charging)
        check(run(&r, 5, true, 80, .charging) == ["charged"], "reaching 80% alerts")
        check(run(&r, 10, true, 81, .charging).isEmpty, "and only once")
        r = AlertRules(); _ = run(&r, 0, false, 21, .battery)
        check(run(&r, 5, false, 20, .battery) == ["low"], "falling to 20% alerts")
        r = AlertRules(); _ = run(&r, 0, true, 21, .charging)
        check(run(&r, 5, true, 20, .held).isEmpty, "a dip to 20% while not draining is silent")
        var off = s; off.low = 0; off.charged = 0; off.dropouts = false; off.draining = false
        r = AlertRules(); _ = run(&r, 0, false, 21, .battery, off)
        check(run(&r, 5, true, 10, .draining, off).isEmpty && run(&r, 300, true, 10, .draining, off).isEmpty, "everything off is silent")

        var p = Reading(); p.fullCap = 5000; p.plugged = true
        check(Model.settle(.charging, p, -0.5, true) == .held, "small dip leaves charging for holding")
        check(Model.settle(.held, p, -0.9, true) == .held, "small deficit does not cry draining")
        check(Model.settle(.draining, p, -0.5, true) == .draining, "draining sticks until clearly over")
        check(Model.settle(.held, p, -5, false) == .held, "no verdict before readings settle")
        check(Model.spread((0..<360).map { (Double($0), 5) }) < 0.001, "steady load has no spread")
        check(Model.spread((0..<360).map { (Double($0), ($0 / 60) % 2 == 0 ? 2 : 12) }) > 4, "alternating load has spread")
        for (path, want) in [("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", "Slack"),
                             ("/System/Library/PrivateFrameworks/AssistantServices.framework/siriactionsd", "macOS"),
                             ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "macOS"),
                             ("/System/Applications/Messages.app/Contents/MacOS/Messages", "Messages"),
                             ("/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari", "Safari"),
                             ("/usr/libexec/corespotlightd", "macOS"), ("/opt/homebrew/bin/node", "Command line tools"), ("/bin/zsh", "Command line tools")] {
            check(AppMeter.identify(path).name == want, "\((path as NSString).lastPathComponent) is \(want)")
        }
        check(brief(3.4) == "3.5h" && brief(0.5) == "30m" && brief(6) == "6h", "short times read well")
        print(failed == 0 ? "all passed" : "\(failed) failed")
        return failed == 0
    }
}
