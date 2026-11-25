import SwiftUI
import Charts
import AppKit

extension Color {
    init(light: UInt32, dark: UInt32) {
        func c(_ h: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? c(dark) : c(light) })
    }
    // One colour per thing, everywhere: charger, Mac, battery.
    static let charger = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let mac = Color(light: 0xEB6834, dark: 0xD95926)
    static let cell = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let critical = Color(light: 0xD03B3B, dark: 0xE66767)
}

struct Card<C: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let trailing { Text(trailing).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: Hero

struct Hero: View {
    @ObservedObject var m: Model
    private var warn: Bool { m.status == .draining || (m.status == .battery && m.now.percent <= 20) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(m.now.percent))").font(.system(size: 64, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText(value: m.now.percent))
                    Text("%").font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.critical) }
                        Text(m.headline)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    Text(m.detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(height: 64)
            GeometryReader { g in
                let f = max(0.02, m.now.percent / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.cell.opacity(0.18))
                    Capsule().fill(m.now.percent <= 10 ? Color.critical : Color.cell).frame(width: max(10, g.size.width * f))
                    Rectangle().fill(.primary.opacity(0.35)).frame(width: 1.5).offset(x: g.size.width * 0.8)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .help("The mark shows 80%, where charging starts to slow.")
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Power flow

/// Ribbon thickness is proportional to watts on one shared scale. Every node keeps its
/// place; the battery branch shrinks away and regrows on the other side when it reverses.
struct Flow: View {
    @ObservedObject var m: Model
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.colorScheme) private var scheme
    static var frame: ((CGSize, Bool) -> CGImage?)?   // Set only while rendering snapshots.

    var body: some View {
        let r = m.smooth
        Card {
            VStack(spacing: 2) {
                HStack(alignment: .top) {
                    node("powerplug.fill", "Charger", r.input, r.plugged ? "in" : "unplugged", .charger, .leading).opacity(r.plugged ? 1 : 0.5)
                    Spacer()
                    node("laptopcomputer", "Your Mac", r.system, "using", .mac, .trailing)
                }
                Group {
                    if let f = Flow.frame, let i = f(CGSize(width: 362, height: 150), scheme == .dark) { Image(decorative: i, scale: 2) }
                    else { FlowSurface(reading: r, running: m.visible, dark: scheme == .dark, calm: still) }
                }
                .frame(height: 150)
                .accessibilityHidden(true)
                node("battery.75percent", "Battery", abs(r.battery), abs(r.battery) < 0.3 ? "idle" : r.battery > 0 ? "charging" : "draining", .cell, .center)
            }
            .frame(height: 238, alignment: .top)
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                small("From the wall", r.plugged ? "≈ " + W(r.wall) : "–")
                small("Lost as heat", r.plugged ? "≈ " + W(max(0, r.wall - r.input)) : "–")
                small("Charger load", r.plugged && r.adapterWatts > 0 ? "\(Int((r.input / r.adapterWatts * 100).rounded()))% of \(Int(r.adapterWatts)) W" : "–")
            }
        }
    }

    private func node(_ icon: String, _ t: String, _ v: Double, _ verb: String, _ c: Color, _ side: HorizontalAlignment) -> some View {
        VStack(alignment: side, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(c)
                Text("\(t) \(verb)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(W(v)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
    private func small(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Estimates

struct Estimates: View {
    @ObservedObject var m: Model
    var body: some View {
        Card(title: "Estimates", trailing: nil) {
            HStack(alignment: .top, spacing: 0) {
                if m.status == .battery || m.status == .draining {
                    tile("Until empty", m.toEmpty)
                    tile("Until 10%", lowTime)
                } else {
                    tile("Until 80%", m.now.percent >= 80 ? 0 : m.to80)
                    tile("Until full", m.status == .full ? 0 : m.toFull)
                }
                if m.now.plugged { tile("If unplugged", m.ifUnplugged, "would last") }
                else { VStack(alignment: .leading, spacing: 2) {
                    Text("Energy left").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(String(format: "%.1f Wh", m.now.remainingWh)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(String(format: "of %.1f Wh", m.now.fullWh)).font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading) }
            }
            if !options.isEmpty && m.now.percent < 95 {
                Divider().opacity(0.6)
                HStack(spacing: 0) {
                    Text(m.now.plugged ? "Full with a\nbigger charger" : "Full if you\nplug in").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(options, id: \.self) { w in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(w)) W").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(m.ready ? m.withCharger(w).map(span) ?? "Not enough" : "–").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    private var options: [Double] {
        let all: [Double] = [30, 70, 96]
        return m.now.plugged ? all.filter { $0 > m.now.adapterWatts * 1.15 } : all
    }
    private var lowTime: Double? {
        guard m.sustained < -0.3 else { return nil }
        return max(0, (m.now.soc - 0.1) * m.now.fullWh / -m.sustained)
    }
    private func tile(_ t: String, _ h: Double?, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(!m.ready ? "–" : h.map { $0 <= 0 ? "Reached" : span($0) } ?? "–")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(note ?? (m.ready ? h.flatMap { $0 > 0 && $0 < 24 ? "at " + clock($0) : nil } ?? " " : " ")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Usage

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func get(_ p: String) -> NSImage {
        if let i = cache[p] { return i }
        let i = NSWorkspace.shared.icon(forFile: p)
        cache[p] = i
        return i
    }
}

struct Usage: View {
    @ObservedObject var m: Model
    private var parts: [(String, Double, Double)] {
        guard let d = m.smooth.display, let p = m.smooth.processor else { return [("Total", m.smooth.system, 1)] }
        return [("Display", d, 1), ("Processor", p, 0.68), ("Everything else", max(0, m.smooth.system - d - p), 0.38)]
    }
    var body: some View {
        Card(title: "What your Mac is using", trailing: W(m.smooth.system)) {
            GeometryReader { g in
                let sum = max(0.1, parts.reduce(0) { $0 + $1.1 })
                let w = g.size.width - CGFloat(parts.count - 1) * 2
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(Color.mac.opacity(p.2)).frame(width: max(0, w * p.1 / sum)).help("\(p.0): \(W(p.1))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 0) {
                ForEach(parts, id: \.0) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle().fill(Color.mac.opacity(p.2)).frame(width: 7, height: 7)
                            Text(p.0).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(W(p.1)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            Divider().opacity(0.6)
            VStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { i in
                    if i < m.apps.count { row(m.apps[i]) } else { Color.clear.frame(height: 18) }
                }
            }
            .overlay { if m.apps.isEmpty { Text("Measuring apps…").font(.system(size: 12)).foregroundStyle(.secondary) } }
            .help("Processor energy for your own apps. The display and system services aren't attributed to apps.")
        }
    }
    private func row(_ a: AppUsage) -> some View {
        HStack(spacing: 8) {
            Group {
                if let p = a.path { Image(nsImage: Icons.get(p)).resizable() }
                else { Image(systemName: "terminal.fill").resizable().scaledToFit().padding(2).foregroundStyle(.secondary) }
            }
            .frame(width: 18, height: 18)
            Text(a.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mac.opacity(0.14))
                    Capsule().fill(Color.mac).frame(width: max(3, g.size.width * min(1, a.watts / max(0.01, m.apps.first?.watts ?? 1))))
                }
            }
            .frame(width: 70, height: 4)
            Text(a.watts < 0.1 ? String(format: "%.0f mW", a.watts * 1000) : String(format: "%.2f W", a.watts))
                .font(.system(size: 12)).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}

// MARK: History

/// An object rather than @State, whose macro plugin is missing from the command line tools.
final class HistoryUI: ObservableObject {
    @Published var hours = 1.0
    @Published var level = false
    @Published var picked: Date?
}

struct History: View {
    @ObservedObject var log: PowerLog
    @StateObject private var ui = HistoryUI()
    private var hours: Double { ui.hours }
    private var level: Bool { ui.level }
    private var picked: Date? { ui.picked }

    private struct Row: Identifiable { var id: String; var date: Date; var value: Double; var series: String; var run: Int }
    private var points: [Point] {
        let from = Date().timeIntervalSince1970 - hours * 3600
        let p = log.points.filter { $0.t >= from }
        let n = max(1, p.count / 240)
        return n == 1 ? p : stride(from: 0, to: p.count, by: n).map { i in
            let s = p[i..<min(p.count, i + n)], c = Double(s.count)
            return Point(t: s.first!.t, input: s.reduce(0) { $0 + $1.input } / c, system: s.reduce(0) { $0 + $1.system } / c, battery: s.reduce(0) { $0 + $1.battery } / c, pct: s.last!.pct)
        }
    }
    private func rows(_ pts: [Point]) -> [Row] {
        var run = 0, out: [Row] = [], prev: Double?
        let gap = max(120, hours * 3600 / 60)
        for p in pts {
            if let q = prev, p.t - q > gap { run += 1 }   // Asleep or quit: leave the line broken.
            prev = p.t
            if level { out.append(Row(id: "L\(p.t)", date: p.date, value: p.pct, series: "Battery level", run: run)) }
            else {
                out.append(Row(id: "C\(p.t)", date: p.date, value: p.input, series: "Charger in", run: run))
                out.append(Row(id: "M\(p.t)", date: p.date, value: p.system, series: "Mac using", run: run))
            }
        }
        return out
    }
    var body: some View {
        let pts = points, hit = picked.flatMap { d in pts.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }
        Card {
            HStack {
                Picker("", selection: $ui.level) { Text("Power").tag(false); Text("Level").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Picker("", selection: $ui.hours) { Text("1h").tag(1.0); Text("6h").tag(6.0); Text("24h").tag(24.0) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 14) {
                if level { key(.cell, "Battery level", hit.map { "\(Int($0.pct))%" }) }
                else { key(.charger, "Charger in", hit.map { W($0.input) }); key(.mac, "Mac using", hit.map { W($0.system) }) }
                Spacer()
                if let hit { Text(hit.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if pts.count < 2 {
                Text("History starts filling in over the next minute.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112)
            } else {
                Chart {
                    ForEach(rows(pts)) { r in
                        LineMark(x: .value("Time", r.date), y: .value("Value", r.value), series: .value("Series", "\(r.series)\(r.run)"))
                            .foregroundStyle(r.series == "Charger in" ? Color.charger : r.series == "Mac using" ? Color.mac : Color.cell)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    if let hit { RuleMark(x: .value("Time", hit.date)).foregroundStyle(.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1)) }
                }
                .chartXScale(domain: Date().addingTimeInterval(-hours * 3600)...Date())
                .chartYScale(domain: 0...(level ? 100 : max(20, (pts.map { max($0.input, $0.system) }.max() ?? 20) * 1.1)))
                .chartXAxis { AxisMarks(values: .stride(by: hours == 1 ? .minute : .hour, count: hours == 1 ? 15 : Int(hours / 4).advanced(by: hours == 6 ? 1 : 0))) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.1))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(level ? "\(Int(d))%" : "\(Int(d)) W") } }
                } }
                .chartXSelection(value: $ui.picked)
                .chartOverlay { proxy in
                    GeometryReader { g in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { ph in
                            if case .active(let p) = ph, let f = proxy.plotFrame { ui.picked = proxy.value(atX: p.x - g[f].minX) } else { ui.picked = nil }
                        }
                    }
                }
                .frame(height: 112)
            }
        }
    }
    private func key(_ c: Color, _ t: String, _ v: String?) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 12, height: 3)
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
            if let v { Text(v).font(.system(size: 11, weight: .semibold)).monospacedDigit() }
        }
    }
}

// MARK: Details

struct Details: View {
    @ObservedObject var m: Model
    var body: some View {
        let r = m.now
        HStack(alignment: .top, spacing: 12) {
            Card(title: "Battery", trailing: nil) {
                VStack(spacing: 6) {
                    kv("Health", "\(Int((r.health * 100).rounded()))%")
                    kv("Cycles", "\(r.cycles) of \(r.ratedCycles)")
                    kv("Stored", String(format: "%.1f / %.1f Wh", r.remainingWh, r.fullWh))
                    kv("Capacity", "\(Int(r.nominal).formatted()) mAh")
                    kv("When new", "\(Int(r.design).formatted()) mAh")
                    kv("Temperature", r.temperature.map { Measurement(value: $0, unit: UnitTemperature.celsius).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0)))) } ?? "–")
                    kv("Electrical", String(format: "%.2f V  %+.2f A", r.volts, r.amps))
                }
            }
            Card(title: "Charger", trailing: nil) {
                if r.plugged {
                    VStack(spacing: 6) {
                        kv("Rated", "\(Int(r.adapterWatts)) W")
                        kv("Agreed", r.contract.map { prof($0) } ?? "–")
                        kv("Arriving", String(format: "%.2f V  %.2f A", r.inVolts, r.inAmps))
                        kv("Delivering", W(r.input))
                        kv("Headroom", W(max(0, r.adapterWatts - r.input)))
                        kv("Efficiency", r.wall > 0 ? "≈ \(Int((r.input / r.wall * 100).rounded()))%" : "–")
                        kv("Offers", r.profiles.isEmpty ? "–" : r.profiles.map { String(format: "%g", $0.volts) }.joined(separator: " · ") + " V")
                            .help(r.profiles.map { prof($0) }.joined(separator: "\n"))
                    }
                } else {
                    Text("Not connected").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 147)
                }
            }
        }
    }
    private func prof(_ p: Profile) -> String { String(format: "%g V  %g A", p.volts, p.amps) }
    private func kv(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(v).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11.5)).frame(height: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Energy mode + footer

struct ModeCard: View {
    @ObservedObject var m: Model
    var body: some View {
        Card {
          HStack {
            Text("Energy mode").font(.system(size: 13, weight: .semibold)).fixedSize()
            Spacer()
            Picker("", selection: Binding(get: { m.mode ?? -1 }, set: { m.setMode($0) })) {
                Text("Automatic").tag(0)
                Text("Low").tag(1)
                Text("High").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(m.modeBusy)
            .help("macOS asks for an administrator to change this.")
          }
        }
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    Hero(m: m).padding(.horizontal, 6).padding(.bottom, 2)
                    Flow(m: m)
                    Estimates(m: m)
                    ModeCard(m: m)
                    Spacer(minLength: 0)
                }
                .frame(width: 390)
                VStack(spacing: 12) { Usage(m: m); History(log: m.log); Details(m: m) }
                .frame(width: 390)
            }
            HStack(spacing: 16) {
                Toggle("Open at login", isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 }))
                Toggle("Watts in menu bar", isOn: Binding(get: { m.menuWatts }, set: { m.menuWatts = $0; m.objectWillChange.send(); m.onUpdate?() }))
                Spacer()
                Button("Battery Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!) }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .toggleStyle(.checkbox).controlSize(.regular).font(.system(size: 12))
            .padding(.horizontal, 6)
        }
        .padding(16)
        .fixedSize()
    }
}
