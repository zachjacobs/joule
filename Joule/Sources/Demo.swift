import Foundation

/// Made-up data and checks, used only by the development flags.
enum Demo {
    /// A day with charging, draining, a sleep gap and a stretch on battery.
    static func history() -> [Point] {
        let now = Date().timeIntervalSince1970
        var out: [Point] = [], pct = 78.0, t = now - 86400
        while t < now {
            let age = (now - t) / 60, wobble = sin(t / 190) * 5 + sin(t / 61) * 4 + Double.random(in: -5...5)
            if !(age > 420 && age < 840), !(age > 26 && age < 33) {
                let plugged = !(age > 8 && age < 20) && !(age > 150 && age < 260) && !(age > 1000 && age < 1150)
                let load = max(7, (age > 60 && age < 100 ? 32 : 22) + wobble), input = plugged ? 25.8 : 0
                pct = min(100, max(4, pct + (input - load) * 20 / 3600 / 61 * 100))
                out.append(Point(t: t, input: input, system: load, battery: input - load, pct: pct, plugged: plugged))
            }
            t += 20
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
