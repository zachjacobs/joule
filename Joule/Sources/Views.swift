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
        HStack(alignment: .center, spacing: 13) {
            Stage(renderer: GaugeRenderer.shared, size: CGSize(width: 46, height: 68), running: m.visible, animated: false) {
                let g = GaugeRenderer.shared
                g.percent = m.now.percent
                g.critical = m.now.percent <= 20 && m.status != .charging
            }
            .padding(.horizontal, -10)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(m.now.percent))").font(.system(size: 56, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText(value: m.now.percent))
                Text("%").font(.system(size: 24, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.critical) }
                    Text(m.headline).lineLimit(1).minimumScaleFactor(0.85)
                }
                .font(.system(size: 15, weight: .semibold))
                Text(m.detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .frame(height: 70)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Power flow

/// Ribbon thickness is proportional to watts on one shared scale. Every node keeps its
/// place; the battery branch shrinks away and regrows on the other side when it reverses.
struct Flow: View {
    @ObservedObject var m: Model

    var body: some View {
        let r = m.smooth
        Card {
            VStack(spacing: 2) {
                HStack(alignment: .top) {
                    node("powerplug.fill", "Charger", r.input, r.plugged ? "in" : "unplugged", .charger, .leading).opacity(r.plugged ? 1 : 0.5)
                    Spacer()
                    node("laptopcomputer", "Your Mac", r.system, "using", .mac, .trailing)
                }
                Stage(renderer: FlowRenderer.shared, size: CGSize(width: 362, height: 190), running: m.visible) { FlowRenderer.shared.reading = m.smooth }
                node("battery.75percent", "Battery", abs(r.battery), abs(r.battery) < 0.3 ? "idle" : r.battery > 0 ? "charging" : "draining", .cell, .center)
            }
            .frame(height: 278, alignment: .top)
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

/// Three tiles that keep their place and meaning whatever the battery is doing.
struct Estimates: View {
    @ObservedObject var m: Model
    var body: some View {
        Card(title: "Estimates", trailing: nil) {
            HStack(alignment: .top, spacing: 0) {
                tile("Until full", full.0, full.1)
                tile(m.now.plugged && m.status != .draining ? "If unplugged" : "Until empty", empty.0, empty.1)
                tile("Net rate", m.ready ? signed(m.sustained) : "–", rate)
            }
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                if !options.isEmpty && m.now.percent < 95 {
                    caption(m.now.plugged ? "Full with a\nbigger charger" : "Full if you\nplug in")
                    ForEach(options, id: \.self) { w in cell("\(Int(w)) W", m.ready ? m.withCharger(w).map(soft) ?? "Not enough" : "–") }
                } else {
                    caption("Unplugged\nwould last")
                    ForEach([6.0, 12, 30], id: \.self) { w in cell("at \(Int(w)) W", m.now.remainingWh > 0 ? soft(m.now.remainingWh / w) : "–") }
                }
            }
        }
    }
    private func caption(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func cell(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private var full: (String, String) {
        guard m.ready else { return ("–", " ") }
        switch m.status {
        case .full: return ("Full", "on the charger")
        case .battery: return ("–", "not plugged in")
        case .draining: return ("–", "losing charge")
        case .held: return ("–", "holding level")
        case .unknown: return ("–", " ")
        case .charging:
            guard let h = m.toFull else { return ("–", "barely gaining") }
            let note = m.uneven ? "load is uneven" : m.now.percent < 80 ? m.to80.map { $0 < 24 ? "80% by \(clock($0))" : " " } ?? " " : "at \(clock(h))"
            return (m.fullText, note)
        }
    }
    private var empty: (String, String) {
        guard m.ready else { return ("–", " ") }
        if m.now.plugged && m.status != .draining { return (m.ifUnplugged.map(soft) ?? "–", "at current use") }
        guard let h = m.toEmpty else { return ("–", "barely draining") }
        return (m.emptyText, m.uneven ? "load is uneven" : h < 24 ? "at \(clock(h))" : " ")
    }
    private var rate: String {
        guard m.ready, m.now.fullWh > 0 else { return " " }
        let p = abs(m.sustained) / m.now.fullWh * 100
        return p < 0.5 ? "steady" : "\(Int(p.rounded()))% per hour"
    }
    private func signed(_ w: Double) -> String { abs(w) < 0.05 ? "0.0 W" : (w > 0 ? "+" : "−") + W(abs(w)) }
    private var options: [Double] {
        let all: [Double] = [30, 70, 96]
        return m.now.plugged ? all.filter { $0 > m.now.adapterWatts * 1.15 } : all
    }
    private func tile(_ t: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
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
        let i = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: p).resolvingSymlinksInPath().path)   // Safari is a link; don't badge it as one.
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
                HStack(spacing: 8) {
                    Text("Processor use by app").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Now").frame(width: 56, alignment: .trailing)
                    Text(m.appMinutes >= 59 ? "Last hour" : "Last \(max(1, m.appMinutes)) min").frame(width: 62, alignment: .trailing)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { i in
                    if i < m.apps.count { row(m.apps[i]) } else { Color.clear.frame(height: 18) }
                }
            }
            .overlay { if m.apps.isEmpty { Text("Measuring apps…").font(.system(size: 12)).foregroundStyle(.secondary) } }
            .help("Ranked by average processor energy. Covers processes running as you; the display, radios and system services running as root aren't included.")
        }
    }
    private func watts(_ w: Double) -> String { w < 0.0005 ? "0 mW" : w < 0.1 ? String(format: "%.0f mW", max(1, w * 1000)) : String(format: "%.2f W", w) }
    private func row(_ a: AppUsage) -> some View {
        HStack(spacing: 8) {
            Group {
                if let p = a.icon { Image(nsImage: Icons.get(p)).resizable() }
                else { Image(systemName: a.symbol).resizable().scaledToFit().padding(2).foregroundStyle(.secondary) }
            }
            .frame(width: 18, height: 18)
            Text(a.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mac.opacity(0.14))
                    Capsule().fill(Color.mac).frame(width: max(3, g.size.width * min(1, a.hour / max(0.001, m.apps.first?.hour ?? 1))))
                }
            }
            .frame(width: 60, height: 4)
            Text(watts(a.watts)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            Text(watts(a.hour)).font(.system(size: 12, weight: .medium)).frame(width: 62, alignment: .trailing)
        }
        .monospacedDigit()
        .frame(height: 18)
        .accessibilityElement(children: .combine)
    }
}

// MARK: History

/// An object rather than @State, whose macro plugin is missing from the command line tools.
final class HistoryUI: ObservableObject {
    static var start = (hours: 1.0, level: false)     // Changed only by snapshots.
    @Published var hours = HistoryUI.start.hours
    @Published var level = HistoryUI.start.level
    @Published var picked: Date?
}

struct History: View {
    @ObservedObject var log: PowerLog
    @StateObject private var ui = HistoryUI()

    /// A stretch of readings with no gap in it, all on the charger or all on battery.
    private struct Run: Identifiable { var id: Int; var pts: [Point]; var onCharger: Bool }
    /// Part of a run where the charger is either ahead of the Mac or behind it.
    private struct Fill: Identifiable { var id: String; var pts: [Point]; var gaining: Bool }
    private struct Band: Identifiable { var id: Int; var from: Date, to: Date; var asleep: Bool }
    private struct Plot { var runs: [Run] = [], fills: [Fill] = [], bands: [Band] = [], top = 20.0 }

    private var bin: Double { max(20, ui.hours * 3600 / 180) }
    private var maxGap: Double { max(90, bin * 2.5) }

    private func plot(_ now: Date) -> Plot {
        let from = now.timeIntervalSince1970 - ui.hours * 3600
        var out = Plot(), group: [Point] = [], runs: [Run] = []
        func close() {
            guard let a = group.first, let z = group.last else { return }
            let c = Double(group.count)
            let p = Point(t: group.reduce(0) { $0 + $1.t } / c, input: group.reduce(0) { $0 + $1.input } / c, system: group.reduce(0) { $0 + $1.system } / c,
                          battery: group.reduce(0) { $0 + $1.battery } / c, pct: z.pct, plugged: a.onCharger)
            if let r = runs.last, let q = r.pts.last, r.onCharger == a.onCharger, p.t - q.t <= maxGap { runs[runs.count - 1].pts.append(p) }
            else { runs.append(Run(id: runs.count, pts: [p], onCharger: a.onCharger)) }
            group = []
        }
        for p in log.points where p.t >= from {
            if let q = group.last, Int(q.t / bin) != Int(p.t / bin) || q.onCharger != p.onCharger || p.t - q.t > maxGap { close() }
            group.append(p)
        }
        close()
        for (i, r) in runs.enumerated() {
            let prev = i > 0 ? runs[i - 1].pts.last!.t : nil
            let first = r.pts.first!.t
            if let prev, first - prev > maxGap {
                out.bands.append(Band(id: out.bands.count, from: Date(timeIntervalSince1970: prev), to: Date(timeIntervalSince1970: first), asleep: true))
            }
            if !r.onCharger {
                let a = prev.map { first - $0 > maxGap ? first : (first + $0) / 2 } ?? first
                let last = r.pts.last!.t
                let next = i + 1 < runs.count ? runs[i + 1].pts.first!.t : nil
                let z = next.map { $0 - last > maxGap ? last : (last + $0) / 2 } ?? now.timeIntervalSince1970
                out.bands.append(Band(id: out.bands.count, from: Date(timeIntervalSince1970: a), to: Date(timeIntervalSince1970: max(z, a + bin)), asleep: false))
            }
        }
        out.runs = runs.map { Run(id: $0.id, pts: soften($0.pts), onCharger: $0.onCharger) }
        for r in out.runs where r.onCharger { out.fills += split(r) }
        out.top = max(20, (out.runs.flatMap(\.pts).map { max($0.input, $0.system) }.max() ?? 20) * (out.bands.isEmpty ? 1.12 : 1.3))
        return out
    }
    /// Gaussian smoothing within a run, so the shape reads without the second-to-second noise.
    private func soften(_ p: [Point]) -> [Point] {
        guard p.count > 3 else { return p }
        return p.indices.map { i in
            var q = p[i], n = 0.0, a = 0.0, b = 0.0, c = 0.0
            for j in max(0, i - 5)...min(p.count - 1, i + 5) {
                let w = exp(-Double((i - j) * (i - j)) / 8)
                n += w; a += p[j].input * w; b += p[j].system * w; c += p[j].battery * w
            }
            q.input = a / n; q.system = b / n; q.battery = c / n
            return q
        }
    }
    /// Cuts a run wherever the two lines cross, adding the crossing to both sides.
    private func split(_ r: Run) -> [Fill] {
        var out: [Fill] = [], part: [Point] = []
        for p in r.pts {
            if let q = part.last {
                let a = q.input - q.system, b = p.input - p.system
                if a * b < 0 {
                    let k = a / (a - b)
                    var x = p
                    x.t = q.t + (p.t - q.t) * k
                    x.input = q.input + (p.input - q.input) * k; x.system = x.input
                    part.append(x)
                    out.append(Fill(id: "\(r.id)-\(out.count)", pts: part, gaining: a > 0))
                    part = [x]
                }
            }
            part.append(p)
        }
        if part.count > 1 { out.append(Fill(id: "\(r.id)-\(out.count)", pts: part, gaining: part.last!.input - part.last!.system > 0 || (part.last!.input == part.last!.system && part[0].input > part[0].system))) }
        return out
    }
    private func ticks(_ now: Date) -> [Date] {
        let step = ui.hours == 1 ? 900.0 : ui.hours == 6 ? 7200 : 21600
        let zone = Double(TimeZone.current.secondsFromGMT(for: now))
        let start = now.timeIntervalSince1970 - ui.hours * 3600
        var t = ((start + zone) / step).rounded(.up) * step - zone, out: [Date] = []
        // Leave room at the right so the last label isn't clipped.
        while t <= now.timeIntervalSince1970 - ui.hours * 330 { out.append(Date(timeIntervalSince1970: t)); t += step }
        return out
    }

    var body: some View {
        let now = Date(), plot = plot(now), all = plot.runs.flatMap(\.pts)
        let near = ui.picked.flatMap { d in all.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }
        let hit = near.flatMap { n in ui.picked.flatMap { abs(n.date.timeIntervalSince($0)) <= maxGap ? n : nil } }
        Card {
            HStack {
                Picker("", selection: $ui.level) { Text("Power").tag(false); Text("Level").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Picker("", selection: $ui.hours) { Text("1h").tag(1.0); Text("6h").tag(6.0); Text("24h").tag(24.0) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            legend(hit)
            if all.count < 2 {
                Text("History starts filling in over the next minute.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104)
            } else { chart(plot, hit, now).frame(height: 104) }
        }
    }
    @ViewBuilder private func legend(_ hit: Point?) -> some View {
        HStack(spacing: 12) {
            if let hit {
                if ui.level { key(.cell, "Level", "\(Int(hit.pct))%") }
                else {
                    if hit.onCharger { key(.charger, "In", W(hit.input)) }
                    key(.mac, "Using", W(hit.system))
                }
                let net = hit.onCharger ? hit.input - hit.system : hit.battery
                swatch(net >= 0 ? .cell : .critical, "\(net >= 0 ? "Gaining" : "Losing") \(W(abs(net)))")
            } else if ui.picked != nil {
                Text("No data here").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if ui.level { key(.cell, "Battery level", nil) }
            else { key(.charger, "Charger in", nil); key(.mac, "Mac using", nil); swatch(.cell, "Gaining"); swatch(.critical, "Losing") }
            Spacer(minLength: 0)
            if let d = hit?.date ?? ui.picked { Text(d.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(height: 14)
    }
    private func chart(_ plot: Plot, _ hit: Point?, _ now: Date) -> some View {
        Chart {
            bands(plot)
            if ui.level { level(plot) } else { power(plot) }
            if let hit { RuleMark(x: .value("Time", hit.date)).foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1)) }
        }
        .chartXScale(domain: now.addingTimeInterval(-ui.hours * 3600)...now)
        .chartYScale(domain: 0...(ui.level ? 100 : plot.top))
        .chartXAxis { AxisMarks(values: ticks(now)) { _ in AxisValueLabel(format: ui.hours == 1 ? .dateTime.hour().minute() : .dateTime.hour()) } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.1))
            AxisValueLabel { if let d = v.as(Double.self) { Text(ui.level ? "\(Int(d))%" : "\(Int(d)) W") } }
        } }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { ph in
                    if case .active(let p) = ph, let f = proxy.plotFrame { ui.picked = proxy.value(atX: p.x - g[f].minX) } else { ui.picked = nil }
                }
            }
        }
    }
    @ChartContentBuilder private func bands(_ plot: Plot) -> some ChartContent {
        ForEach(plot.bands) { b in
            RectangleMark(xStart: .value("From", b.from), xEnd: .value("To", b.to))
                .foregroundStyle(Color.primary.opacity(b.asleep ? 0.05 : 0.10))
                .annotation(position: .overlay, alignment: .top) {
                    if b.to.timeIntervalSince(b.from) > ui.hours * 3600 * 0.17 {
                        Text(b.asleep ? "No data" : "On battery").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }
        }
    }
    @ChartContentBuilder private func power(_ plot: Plot) -> some ChartContent {
        ForEach(plot.fills) { f in
            ForEach(f.pts) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Charger", p.input), yEnd: .value("Mac", p.system), series: .value("Part", f.id))
                    .foregroundStyle((f.gaining ? Color.cell : Color.critical).opacity(0.28))
            }
        }
        ForEach(plot.runs) { r in
            if r.onCharger {
                ForEach(r.pts) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Watts", p.input), series: .value("Series", "in\(r.id)"))
                        .foregroundStyle(Color.charger).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(r.pts) { p in
                LineMark(x: .value("Time", p.date), y: .value("Watts", p.system), series: .value("Series", "mac\(r.id)"))
                    .foregroundStyle(Color.mac).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
    @ChartContentBuilder private func level(_ plot: Plot) -> some ChartContent {
        ForEach(plot.runs) { r in
            ForEach(r.pts) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Level", p.pct), series: .value("Series", "a\(r.id)")).foregroundStyle(Color.cell.opacity(0.14))
                LineMark(x: .value("Time", p.date), y: .value("Level", p.pct), series: .value("Series", "l\(r.id)"))
                    .foregroundStyle(Color.cell).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
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
    private func swatch(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.4)).frame(width: 9, height: 9)
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
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

struct AlertsMenu: View {
    @ObservedObject var m: Model
    @ObservedObject var notifier: Notifier
    var body: some View {
        Menu {
            if notifier.blocked {
                Button("Notifications are off for Joule. Open Settings…") { notifier.openSettings() }
                Divider()
            }
            Toggle("Plugged in but draining", isOn: $m.alerts.draining)
            Toggle("Charger drops out", isOn: $m.alerts.dropouts)
            Picker("Charged to", selection: $m.alerts.charged) {
                Text("Off").tag(0); Text("80%").tag(80); Text("90%").tag(90); Text("100%").tag(100)
            }
            Picker("Battery falls to", selection: $m.alerts.low) {
                Text("Off").tag(0); Text("10%").tag(10); Text("15%").tag(15); Text("20%").tag(20); Text("30%").tag(30)
            }
            Divider()
            Button("Send a test alert") { notifier.post(Note(id: "test", title: "Joule alerts are working", body: m.headline + ". " + m.detail)) }
        } label: {
            Label("Alerts", systemImage: notifier.blocked ? "bell.slash" : "bell")
        }
        .labelStyle(.titleAndIcon).fixedSize()
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    var notifier: Notifier
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
                AlertsMenu(m: m, notifier: notifier)
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
