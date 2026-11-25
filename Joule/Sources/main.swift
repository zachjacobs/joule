import AppKit
import SwiftUI

final class Delegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = Model()
    var item: NSStatusItem!
    let pop = NSPopover()
    var window: NSWindow?
    private var lastTitle = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 { return snapshot(args[i + 1], dark: !args.contains("--light")) }
        if let i = args.firstIndex(of: "--frames"), args.count > i + 1 { return frames(args[i + 1]) }
        if let i = args.firstIndex(of: "--icon"), args.count > i + 1 { return icon(args[i + 1]) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Joule"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        pop.behavior = .transient
        pop.delegate = self
        let host = NSHostingController(rootView: Panel(m: model))
        host.sizingOptions = .preferredContentSize
        pop.contentViewController = host
        model.onUpdate = { [weak self] in self?.refresh() }
        refresh()
        if args.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() } }
    }
    func applicationWillTerminate(_ n: Notification) { if window == nil { model.flush() } }

    private func refresh() {
        guard let b = item?.button else { return }
        let r = model.now
        let w = model.menuWatts && r.fullCap > 0 ? String(format: "  %+.0f W", model.sustained).replacingOccurrences(of: "-", with: "−").replacingOccurrences(of: "+0 W", with: "0 W").replacingOccurrences(of: "−0 W", with: "0 W") : ""
        let title = " \(Int(r.percent))%\(w)"
        let key = "\(title)\(r.plugged)\(model.status)"
        guard key != lastTitle else { return }
        lastTitle = key
        b.image = glyph(r.percent / 100, bolt: r.plugged, warn: model.status == .draining)
        b.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)])
        b.setAccessibilityLabel("Battery \(Int(r.percent)) percent, \(model.headline)")
        b.toolTip = "\(model.headline). \(model.detail)"
    }

    private func glyph(_ f: Double, bolt: Bool, warn: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: bolt ? 36 : 27, height: 14), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let body = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 1.25, width: 22.5, height: 11.5), xRadius: 3.8, yRadius: 3.8)
            body.lineWidth = 1.2
            NSColor.black.withAlphaComponent(0.5).setStroke(); body.stroke()
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: NSRect(x: 24.4, y: 5, width: 1.6, height: 4), xRadius: 0.8, yRadius: 0.8).fill()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 3, width: max(2, 19 * f), height: 8), xRadius: 2, yRadius: 2).fill()
            if bolt, let s = NSImage(systemSymbolName: warn ? "exclamationmark" : "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
                s.draw(in: NSRect(x: 28 + (7 - s.size.width * 0.8) / 2, y: 7 - s.size.height * 0.4, width: s.size.width * 0.8, height: s.size.height * 0.8))
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if pop.isShown { pop.performClose(nil); return }
        model.visible = true
        NSApp.activate(ignoringOtherApps: true)
        // Settle the size first; growing after opening would push the panel off screen.
        if let v = pop.contentViewController?.view { v.layoutSubtreeIfNeeded(); pop.contentSize = v.fittingSize }
        pop.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        pop.contentViewController?.view.window?.makeKey()
        if CommandLine.arguments.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
            guard let w = pop.contentViewController?.view.window else { return }
            print("panel \(w.frame) frames \(FlowRenderer.shared.frames)")
            // An app may capture its own window without screen-recording permission.
            typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), let path = CommandLine.arguments.last, path.hasSuffix(".png") {
                for n in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.5) {
                    if let i = unsafeBitCast(f, to: Grab.self)(.null, 8, UInt32(w.windowNumber), 1)?.takeRetainedValue() {
                        try? NSBitmapImageRep(cgImage: i).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "\(n).png")))
                    }
                } }
            }
        } }
    }
    func popoverDidClose(_ n: Notification) { model.visible = false }

    /// Development aid: flow frames across states, as one contact sheet.
    private func frames(_ path: String) {
        let f = FlowRenderer.shared, size = CGSize(width: 362, height: 126), scale: CGFloat = 2
        let states: [(Double, Double, Bool)] = [(25.8, 13, true), (25.8, 24.5, true), (25.8, 37.6, true), (0, 15, true), (25.8, 13, false), (90, 30, true)]
        let W = Int(size.width * scale), H = Int(size.height * scale), cols = 3
        let ctx = CGContext(data: nil, width: W * cols, height: H * states.count, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (row, s) in states.enumerated() {
            var r = Reading(); r.input = s.0; r.system = s.1; r.battery = s.0 - s.1; r.adapterWatts = s.0 > 60 ? 96 : s.0 > 0 ? 27 : 0
            f.reading = r; f.dark = s.2; f.advance(nil)
            for c in 0..<cols {
                f.advance(0.1); f.advance(0.1); f.advance(0.1); f.advance(0.1)
                let rect = CGRect(x: c * W, y: (states.count - 1 - row) * H, width: W, height: H)
                ctx.setFillColor(s.2 ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.95, alpha: 1)); ctx.fill(rect)
                if let i = f.image(size, scale: scale) { ctx.draw(i, in: rect) }
            }
        }
        try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    /// Used by build.sh to draw the app icon.
    private func icon(_ path: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        func rgb(_ h: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }
        let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
        rgb(0x1B1C1F).setFill(); plate.fill()
        plate.addClip()
        for (y0, y1, h, a, b) in [(512.0 + 52, 512.0 + 150, 200.0, 0x3987E5, 0xD95926), (512.0 - 108, 512.0 - 206, 108.0, 0x3987E5, 0x199E70)] as [(Double, Double, Double, UInt32, UInt32)] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 100, y: y0 + h / 2))
            p.curve(to: NSPoint(x: 924, y: y1 + h / 2), controlPoint1: NSPoint(x: 512, y: y0 + h / 2), controlPoint2: NSPoint(x: 512, y: y1 + h / 2))
            p.line(to: NSPoint(x: 924, y: y1 - h / 2))
            p.curve(to: NSPoint(x: 100, y: y0 - h / 2), controlPoint1: NSPoint(x: 512, y: y1 - h / 2), controlPoint2: NSPoint(x: 512, y: y0 - h / 2))
            p.close()
            NSGradient(starting: rgb(a), ending: rgb(b))!.draw(in: p, angle: 0)
        }
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    /// Development aid: render the live panel to a PNG and exit.
    private func snapshot(_ path: String, dark: Bool) {
        if CommandLine.arguments.contains("--demo-battery") {
            model.adjust = { r in r.plugged = false; r.charging = false; r.input = 0; r.wall = 0; r.battery = -r.system; r.percent = 64; r.remaining = r.fullCap * 0.64 }
        }
        if CommandLine.arguments.contains("--demo-charge") {
            model.adjust = { r in r.input = 25.8; r.system = 13; r.battery = 12.8; r.display = 7; r.processor = 3 }
        }
        if CommandLine.arguments.contains("--demo-drain") {
            model.adjust = { r in r.input = 25.8; r.system = 37.6; r.battery = -11.8; r.display = 7; r.processor = 18 }
        }
        Flow.frame = { [model] size, dark in
            let f = FlowRenderer.shared
            f.reading = model.smooth; f.dark = dark; f.advance(1); f.advance(0.1)
            return f.image(size)
        }
        let root = Panel(m: model).background(Color(nsColor: .windowBackgroundColor))
        let v = NSHostingView(rootView: root)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = v
        w.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        w.orderFrontRegardless()
        window = w
        model.visible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 48) {
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print(v.bounds.size, self.model.now)
            self.model.flush()
            exit(0)
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
