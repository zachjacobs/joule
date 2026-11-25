import AppKit
import UserNotifications

struct AlertSettings: Codable, Equatable {
    var draining = true
    var dropouts = true
    var charged = 80     // 0 turns it off
    var low = 20

    private static let key = "alerts"
    static func load() -> AlertSettings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
    }
    func store() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: AlertSettings.key) }
}

struct Note: Equatable { var id: String, title: String, body: String }

/// Decides what deserves an alert. Holds no clock or UI, so it can be tested with made-up time.
struct AlertRules {
    private var percent: Double?
    private var plugged: Bool?
    private var drainingSince: Date?
    private var warnedDraining: Date?
    private var unpluggedAt: Date?
    private var drops: [Date] = []

    mutating func step(_ t: Date, plugged now: Bool, percent p: Double, status: Status, deficit: Double, adapter: Double, left: String?, _ s: AlertSettings) -> [Note] {
        var out: [Note] = []
        if let was = plugged, was != now {
            drainingSince = nil
            if now {
                warnedDraining = nil
                if let u = unpluggedAt, t.timeIntervalSince(u) <= 30 {
                    drops = drops.filter { Calendar.current.isDate($0, inSameDayAs: t) } + [t]
                    if s.dropouts {
                        let n = drops.count, gap = max(1, Int(t.timeIntervalSince(u).rounded()))
                        out.append(Note(id: "drop", title: "Charger dropped out for \(gap) second\(gap == 1 ? "" : "s")",
                                        body: (n > 1 ? "That's \(n) times today. " : "") + "If you didn't unplug it, check the cable and port."))
                    }
                }
                unpluggedAt = nil
            } else { unpluggedAt = t }
        }
        if status == .draining {
            let since = drainingSince ?? t
            drainingSince = since
            let quiet = warnedDraining.map { t.timeIntervalSince($0) > 3600 } ?? true
            if s.draining, quiet, t.timeIntervalSince(since) >= 180 {
                warnedDraining = t
                out.append(Note(id: "draining", title: "Plugged in, but draining",
                                body: "Your Mac needs \(W(deficit)) more than this\(adapter > 0 ? " \(Int(adapter)) W" : "") charger supplies." + (left.map { " About \($0) left at this rate." } ?? "")))
            }
        } else { drainingSince = nil }
        if let was = percent {
            let up = Double(s.charged), down = Double(s.low)
            if s.charged > 0, now, was < up, p >= up {
                out.append(Note(id: "charged", title: s.charged == 100 ? "Fully charged" : "Charged to \(s.charged)%", body: s.charged == 100 ? "You can unplug now." : "Stopping here is easier on the battery."))
            }
            if s.low > 0, !now || status == .draining, was > down, p <= down {
                out.append(Note(id: "low", title: "Battery at \(Int(p))%", body: left.map { "About \($0) left at this rate." } ?? "Plug in soon."))
            }
        }
        percent = p; plugged = now
        return out
    }
}

final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var blocked = false
    private let center = UNUserNotificationCenter.current()

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, e in
            if let e { NSLog("Joule notifications: \(e.localizedDescription)") }
            DispatchQueue.main.async { self.blocked = !ok }
        }
    }
    func recheck() {
        center.getNotificationSettings { s in
            DispatchQueue.main.async { self.blocked = s.authorizationStatus == .denied }
        }
    }
    func post(_ n: Note) {
        let c = UNMutableNotificationContent()
        c.title = n.title; c.body = n.body; c.sound = .default
        // Reusing the id replaces an older alert of the same kind instead of piling up.
        center.add(UNNotificationRequest(identifier: n.id, content: c, trigger: nil)) { e in
            if let e { NSLog("Joule notification failed: \(e.localizedDescription)") }
        }
    }
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
