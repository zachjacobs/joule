import SwiftUI
import MetalKit

/// Compiled at launch, so building needs no Metal toolchain.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U {
    float2 size; float scale; float dark;
    float main, charge, drain, pad;
    float pMain, pCharge, pDrain, calm;
    float4 charger, mac, cell, violet, teal, gold;
};
struct V { float4 pos [[position]]; };
vertex V vs(uint i [[vertex_id]]) {
    float2 p = float2((i << 1) & 2, i & 2);
    return { float4(p * 2 - 1, 0, 1) };
}
static float hash(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
// Distance to a ribbon with rounded ends: s along it (0...L), d across it.
static float box(float s, float d, float L, float h) {
    float r = min(h, 5.0);
    float2 q = abs(float2(s - L * 0.5, d)) - float2(L * 0.5, h) + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
// Streaks of light on fine parallel strands. Strands sit at fixed distances from the
// centreline, so a wider ribbon simply uncovers more of them.
static float2 strands(float s, float d, float L, float h, float phase, float seed) {
    const float pitch = 4.0, period = 150.0;
    float head = 0, tail = 0;
    float k0 = round(d / pitch);
    for (int j = -1; j <= 1; j++) {
        float k = k0 + j, c = k * pitch;
        float room = smoothstep(0.0, 1.6, h - abs(c) - 0.4);
        if (room <= 0) { if (k == 0) room = 1; else continue; }
        // Golden-ratio spacing keeps neighbouring strands from bunching up.
        float r1 = fract((k + 32.0) * 0.6180340 + seed), r2 = hash(float2(k + 41.0, seed * 17.0 + 9.0));
        float speed = 0.92 + 0.16 * r2;
        // x runs 0 at a streak's head to 1 at the end of its tail.
        float x = fract((phase * speed - s) / period + r1);
        float len = 0.45 + 0.35 * hash(float2(k + 5.0, seed + 2.0));
        float t = saturate(x / len);
        float nose = smoothstep(0.0, 0.035, x);
        float body = pow(1.0 - t, 2.2) * nose;
        float across = d - c;
        float w = min(0.85, max(0.45, h * 0.6));
        float core = exp(-across * across / (w * w));
        float halo = exp(-across * across / 9.0);
        head += room * pow(1.0 - t, 9.0) * nose * core;
        tail += room * body * (core * 0.85 + halo * 0.16);
    }
    return float2(head, tail);
}
// Returns premultiplied colour for one ribbon.
static float4 paint(float s, float d, float L, float th, float phase, float3 a, float3 m, float3 b, constant U &u, float seed) {
    float h = th * 0.5;
    if (th < 0.15) return float4(0);
    float vis = smoothstep(0.15, 1.4, th);
    float dist = box(s, d, L, h);
    float aa = 0.5 / u.scale;
    float inside = 1 - smoothstep(-aa, aa, dist);
    float t = clamp(s / L, 0.0, 1.0);
    float3 col = t < 0.5 ? mix(a, m, smoothstep(0.0, 1.0, t * 2)) : mix(m, b, smoothstep(0.0, 1.0, t * 2 - 1));
    bool dark = u.dark > 0.5;
    // Thin ribbons need a denser base to stay visible.
    float thin = 1 - smoothstep(3.0, 9.0, th);
    float base = mix(dark ? 0.40 : 0.30, 0.62, thin);
    float rim = (1 - smoothstep(0.0, 1.1, -dist)) * (dark ? 0.30 : 0.26);
    float ends = smoothstep(2.0, 34.0, s) * smoothstep(2.0, 34.0, L - s);
    float2 l = strands(s, d, L, h, phase, seed) * ends * (1 - u.calm);
    float lit = saturate(l.y);
    float3 c = mix(col, dark ? mix(col, float3(1), 0.42) : mix(col, float3(0), 0.04), lit);
    c = mix(c, dark ? float3(1) : mix(col, float3(0), 0.16), saturate(l.x) * 0.85);
    float alpha = saturate(base + rim + lit * 0.85 + l.x * 0.4) * inside * vis;
    float4 o = float4(c * alpha, alpha);
    // A faint bloom lifts the ribbon off the card in dark mode.
    float glow = (1 - inside) * exp(-max(dist, 0.0) / 7.0) * (dark ? 0.13 : 0.0) * vis
        * smoothstep(-4.0, 24.0, s) * smoothstep(-4.0, 24.0, L - s);
    o += float4(col * glow, glow) * (1 - o.a);
    return o;
}
// A branch that leaves the top line, rounds a corner and drops to the battery.
static float2 elbow(float2 p, float yc, float cx, float R, float bottom, thread float &L) {
    float2 C = float2(cx - R, yc + R);
    float arc = R * M_PI_2_F;
    L = C.x + arc + max(0.0, bottom - C.y);
    if (p.x < C.x && p.y < C.y) return float2(p.x, p.y - yc);
    if (p.x < C.x) return float2(p.x, p.y - yc);
    if (p.y >= C.y) return float2(C.x + arc + p.y - C.y, cx - p.x);
    float2 q = p - C;
    return float2(C.x + R * atan2(q.x, -q.y), R - length(q));
}
fragment float4 fs(V in [[stage_in]], constant U &u [[buffer(0)]]) {
    float2 p = in.pos.xy / u.scale;
    float W = u.size.x, cx = W * 0.5, top = 8, bottom = u.size.y - 8, L;
    float gap = 2.5 * smoothstep(0.0, 2.0, u.main);
    float inset = 2;
    float2 pi = float2(p.x - inset, p.y);
    float LW = W - inset * 2;
    float4 o = float4(0);

    float4 r = paint(pi.x, p.y - (top + u.main * 0.5), LW, u.main, u.pMain, u.charger.rgb, u.violet.rgb, u.mac.rgb, u, 0.0);
    o = r;
    float R = u.charge * 0.5 + 16;
    float yc = top + u.main + gap + u.charge * 0.5;
    float2 sd = elbow(pi, yc, cx - inset, R, bottom, L);
    r = paint(sd.x, sd.y, L, u.charge, u.pCharge, u.charger.rgb, u.teal.rgb, u.cell.rgb, u, 0.37);
    o = o + r * (1 - o.a);
    R = u.drain * 0.5 + 16;
    yc = top + u.main + gap + u.drain * 0.5;
    sd = elbow(float2(LW - pi.x, p.y), yc, LW - (cx - inset), R, bottom, L);
    r = paint(L - sd.x, sd.y, L, u.drain, u.pDrain, u.cell.rgb, u.gold.rgb, u.mac.rgb, u, 0.71);
    o = o + r * (1 - o.a);
    return o;
}
"""

struct FlowUniforms {
    var size = SIMD2<Float>(0, 0), scale: Float = 2, dark: Float = 1
    var main: Float = 0, charge: Float = 0, drain: Float = 0, pad: Float = 0
    var pMain: Float = 0, pCharge: Float = 0, pDrain: Float = 0, calm: Float = 0
    var charger = SIMD4<Float>(repeating: 0), mac = SIMD4<Float>(repeating: 0), cell = SIMD4<Float>(repeating: 0)
    var violet = SIMD4<Float>(repeating: 0), teal = SIMD4<Float>(repeating: 0), gold = SIMD4<Float>(repeating: 0)
}

/// Eases ribbon widths toward the latest reading, and advances each stream's position by
/// integrating its speed, so a change in power never makes the light skip.
final class FlowRenderer: NSObject, MTKViewDelegate {
    static let shared = FlowRenderer()
    let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = {
        guard let device else { return nil }
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs")
            d.fragmentFunction = lib.makeFunction(name: "fs")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        } catch { NSLog("Joule flow shader: \(error)"); return nil }
    }()
    var reading = Reading()
    var dark = true
    var calm = false
    private(set) var frames = 0
    private var main = 0.0, charge = 0.0, drain = 0.0, span = 40.0
    private var phases = SIMD3<Double>(40, 90, 140)
    private var last: CFTimeInterval?

    private func rgb(_ h: UInt32) -> SIMD4<Float> { SIMD4(Float(h >> 16 & 255) / 255, Float(h >> 8 & 255) / 255, Float(h & 255) / 255, 1) }

    func advance(_ dt: Double?) {
        let r = reading, out = max(0, -r.battery)
        let goal = (min(r.input, r.system), max(0, r.battery), out, max(40, r.adapterWatts, r.input + out))
        let k = dt.map { 1 - exp(-min($0, 1) / 0.8) } ?? 1
        main += (goal.0 - main) * k
        charge += (goal.1 - charge) * k
        drain += (goal.2 - drain) * k
        span += (goal.3 - span) * k
        let d = min(dt ?? 0, 0.1)
        func speed(_ w: Double) -> Double { 34 + min(60, w) * 0.9 }
        phases += SIMD3(speed(main), speed(charge), speed(drain)) * d
    }
    private func uniforms(_ size: CGSize, _ scale: CGFloat) -> FlowUniforms {
        var u = FlowUniforms()
        u.size = SIMD2(Float(size.width), Float(size.height)); u.scale = Float(scale); u.dark = dark ? 1 : 0
        let px = 54 / span
        u.main = Float(main * px); u.charge = Float(charge * px); u.drain = Float(drain * px)
        // Keep numbers small enough for float precision over long sessions.
        func wrap(_ x: Double) -> Float { Float(x.truncatingRemainder(dividingBy: 248_640)) }
        u.pMain = wrap(phases.x); u.pCharge = wrap(phases.y); u.pDrain = wrap(phases.z); u.calm = calm ? 1 : 0
        u.charger = rgb(dark ? 0x3987E5 : 0x2A78D6); u.mac = rgb(dark ? 0xD95926 : 0xEB6834); u.cell = rgb(dark ? 0x199E70 : 0x1BAF7A)
        // Hand-picked midpoints: blending straight between the node colours turns grey.
        u.violet = rgb(dark ? 0x9A68C9 : 0x9A5CC0); u.teal = rgb(dark ? 0x22A0B8 : 0x1F9FB5); u.gold = rgb(dark ? 0xB59A2C : 0xC7A32E)
        return u
    }
    private func encode(_ pass: MTLRenderPassDescriptor, _ size: CGSize, _ scale: CGFloat) -> MTLCommandBuffer? {
        guard let pipeline, let cb = queue?.makeCommandBuffer(), let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var u = uniforms(size, scale)
        e.setRenderPipelineState(pipeline)
        e.setFragmentBytes(&u, length: MemoryLayout<FlowUniforms>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        return cb
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        advance(last.map { now - $0 })
        last = now
        let s = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 2
        guard let pass = view.currentRenderPassDescriptor, let d = view.currentDrawable,
              let cb = encode(pass, view.bounds.size, s) else { return }
        cb.present(d); cb.commit()
        frames += 1
    }

    /// Off-screen frame, for snapshots.
    func image(_ size: CGSize, scale: CGFloat = 2) -> CGImage? {
        guard let device else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]; td.storageMode = .shared
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let cb = encode(pass, size, scale) else { return nil }
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        t.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
    }
}

struct FlowSurface: NSViewRepresentable {
    var reading: Reading
    var running: Bool
    var dark: Bool
    var calm: Bool

    final class Surface: MTKView {
        override var isOpaque: Bool { false }
        override func hitTest(_ p: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Surface {
        let v = Surface(frame: .zero, device: FlowRenderer.shared.device)
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.layer?.isOpaque = false
        (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.preferredFramesPerSecond = 60
        v.delegate = FlowRenderer.shared
        return v
    }
    func updateNSView(_ v: Surface, context: Context) {
        let r = FlowRenderer.shared
        r.reading = reading; r.dark = dark; r.calm = calm
        // With Reduce Motion on, redraw once per reading instead of animating.
        v.enableSetNeedsDisplay = calm
        v.isPaused = calm || !running
        if calm { v.needsDisplay = true }
    }
}
