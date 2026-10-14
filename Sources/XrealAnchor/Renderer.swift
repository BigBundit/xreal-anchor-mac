import Foundation
import MetalKit
import QuartzCore
import AppKit
import os
import simd

/// Everything the shader needs to draw one frame.
struct FrameParams {
    /// Rotation from the glasses' view to screen-anchor space.
    var rotation: simd_float3x3
    /// Diagonal field of view of the glasses, degrees.
    var fovDiagonal: Float
    /// Horizontal angle covered by the virtual screen, degrees.
    var screenAngle: Float
    var curved: Bool
    /// Head angular velocity in the view frame (rad/s), for per-scanline prediction.
    var angularVelocity: SIMD3<Float> = .zero
    /// How much later the bottom row is shown than the top row, seconds.
    var scanlineSpan: Float = 0
    /// How far the lenses sit in front of the neck pivot, as a fraction of screen distance.
    var lensOffset: Float = 0
    /// Overlay a grid for tuning stability.
    var showGrid = false
}

private struct Uniforms {
    var rot: simd_float4x4
    var p0: SIMD4<Float>  // tanHalfX, tanHalfY, screenW, screenH
    var omega: SIMD4<Float>  // angular velocity (rad/s) xyz, scanline span (s)
    var p3: SIMD4<Float>  // lens offset, show grid
    var p1: SIMD4<Float>  // distance, curved, pixel size in NDC (x, y)
    var p2: SIMD4<Float>  // hasTexture
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float4x4 rot; float4 p0; float4 omega; float4 p3; float4 p1; float4 p2; };
struct VOut { float4 pos [[position]]; float2 ndc; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.ndc = p * 2.0 - 1.0;
    o.pos = float4(o.ndc, 0.0, 1.0);
    return o;
}

// Casts a ray from the eye through an NDC point and returns the colour on the virtual screen.
// The neck is the pivot at the origin; the eye sits `lens` in front of it, so turning the head
// also moves the eye, like it does in reality.
static float4 shade(float2 ndc, constant Uniforms& u, texture2d<float> tex, sampler s) {
    float3 d = normalize(float3(ndc.x * u.p0.x, ndc.y * u.p0.y, -1.0));
    // Lower rows reach the eye later: rotate them a little further along the head motion.
    float scan = (1.0 - ndc.y) * 0.5;
    d += cross(u.omega.xyz * (scan * u.omega.w), d);
    float3x3 r = float3x3(u.rot[0].xyz, u.rot[1].xyz, u.rot[2].xyz);
    d = r * d;
    float lens = u.p3.x;
    float3 o = r * float3(0.0, 0.0, -lens);
    float dist = u.p1.x;
    float2 uv;
    if (u.p1.y > 0.5) {
        // Cylinder of radius `dist` around the neck.
        float a = dot(d.xz, d.xz);
        if (a < 1e-8) return float4(0);
        float b = 2.0 * dot(o.xz, d.xz);
        float c = dot(o.xz, o.xz) - dist * dist;
        float t = (-b + sqrt(max(b * b - 4.0 * a * c, 0.0))) / (2.0 * a);
        float3 hit = o + d * t;
        float theta = atan2(hit.x, -hit.z);
        uv = float2(theta * dist / u.p0.z + 0.5, 0.5 - hit.y / u.p0.w);
    } else {
        if (d.z > -1e-5) return float4(0);
        float t = (-dist - o.z) / d.z;
        float3 hit = o + d * t;
        uv = float2(hit.x / u.p0.z + 0.5, 0.5 - hit.y / u.p0.w);
    }
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0);
    float4 c = tex.sample(s, uv);
    if (u.p3.y > 0.5) {
        // Tuning grid: 16 x 9 cells plus a centre cross.
        float2 g = abs(fract(uv * float2(16.0, 9.0) + 0.5) - 0.5) / fwidth(uv * float2(16.0, 9.0));
        float line = 1.0 - clamp(min(g.x, g.y) - 0.5, 0.0, 1.0);
        float2 cc = abs(uv - 0.5) / fwidth(uv);
        float centre = (cc.x < 1.5 || cc.y < 1.5) && all(abs(uv - 0.5) < 0.04) ? 1.0 : 0.0;
        c = mix(c * 0.55, float4(0.2, 1.0, 0.4, 1.0), max(line * 0.9, centre));
    }
    return c;
}

fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                      texture2d<float> tex [[texture(0)]]) {
    if (u.p2.x < 0.5) return float4(0, 0, 0, 1);
    constexpr sampler s(filter::linear, mip_filter::none, address::clamp_to_zero);
    // Rotated-grid 4x supersampling keeps text readable while the screen is resampled.
    float2 px = u.p1.zw;
    float4 c = shade(in.ndc + px * float2( 0.125,  0.375), u, tex, s)
             + shade(in.ndc + px * float2(-0.375,  0.125), u, tex, s)
             + shade(in.ndc + px * float2( 0.375, -0.125), u, tex, s)
             + shade(in.ndc + px * float2(-0.125, -0.375), u, tex, s);
    return float4((c * 0.25).rgb, 1.0);
}
"""

/// Draws the virtual screen into the glasses' drawable.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Log.info("shader error \(error)")
            return nil
        }
    }

    func render(to drawable: CAMetalDrawable, params: FrameParams, texture: MTLTexture?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let width = Float(drawable.texture.width), height = Float(drawable.texture.height)
        let aspect = width / max(height, 1)
        // Split the diagonal FOV the way Breezy Desktop does for these glasses: the angle is
        // shared out linearly by aspect ratio, which matches the optics better than tangents.
        let halfV = params.fovDiagonal / sqrt(aspect * aspect + 1) * .pi / 360
        let tanX = tan(halfV * aspect)
        let tanY = tan(halfV)

        let texAspect: Float = texture.map { Float($0.width) / Float(max($0.height, 1)) } ?? 16 / 9
        let angle = params.screenAngle * .pi / 180
        let distance: Float = 1
        // Size the screen as seen from the eye, which sits `lensOffset` in front of the pivot.
        let eyeDistance = distance * (1 - params.lensOffset)
        let screenW = params.curved ? angle * eyeDistance : 2 * eyeDistance * tan(angle / 2)
        let screenH = screenW / texAspect

        let r = params.rotation
        var u = Uniforms(
            rot: simd_float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, 0, 0, 1)),
            p0: SIMD4(tanX, tanY, screenW, screenH),
            omega: SIMD4(params.angularVelocity, params.scanlineSpan),
            p3: SIMD4(params.lensOffset * distance, params.showGrid ? 1 : 0, 0, 0),
            p1: SIMD4(distance, params.curved ? 1 : 0, 2 / width, 2 / height),
            p2: SIMD4(texture == nil ? 0 : 1, 0, 0, 0)
        )

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let texture { enc.setFragmentTexture(texture, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// A view whose backing layer is the CAMetalLayer we draw the glasses' image into.
final class GlassesView: NSView {
    let metalLayer = CAMetalLayer()

    init(frame: NSRect, device: MTLDevice) {
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// Drives rendering from a CAMetalDisplayLink on its own thread, so frames are paced by the
/// glasses' display and never wait on the main thread. Each frame is posed for the moment it
/// will actually be shown.
final class RenderLoop: NSObject, CAMetalDisplayLinkDelegate {
    private let renderer: Renderer
    private let link: CAMetalDisplayLink
    private let poseForTime: (CFTimeInterval) -> FrameParams
    private let textureProvider: () -> MTLTexture?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    private var lock = os_unfair_lock()
    private var frameTimes: [CFTimeInterval] = []
    private var lastFrame: CFTimeInterval = 0
    private var worstGap: CFTimeInterval = 0
    private var slowFrames = 0
    private var deadlineLeadMs: Double = 0
    private var latencySum: Double = 0
    private var targetErrorSum: Double = 0
    private var latencyCount = 0
    /// Smoothed difference between when frames are really shown and when the link said they would be.
    private var presentOffsetEMA: CFTimeInterval = 0

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Precise sleep until a CACurrentMediaTime timestamp.
    static func sleep(until time: CFTimeInterval) {
        let ticks = UInt64(time * 1e9 * Double(timebase.denom) / Double(timebase.numer))
        mach_wait_until(ticks)
    }

    init(layer: CAMetalLayer, renderer: Renderer, pose: @escaping (CFTimeInterval) -> FrameParams,
         texture: @escaping () -> MTLTexture?) {
        self.renderer = renderer
        self.poseForTime = pose
        self.textureProvider = texture
        link = CAMetalDisplayLink(metalLayer: layer)
        super.init()
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.preferredFrameLatency = 1
    }

    func start() {
        let t = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            self.link.add(to: .current, forMode: .default)
            CFRunLoopRun()
        }
        t.name = "XrealAnchor.render"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [link] in
            link.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
        runLoop = nil
        thread = nil
    }

    /// Time kept in hand before the render deadline for encoding and GPU work, seconds.
    var renderMargin: CFTimeInterval = 0.003

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The link asks for frames several refreshes early. Sleep until just before the render
        // deadline and only then read the head pose ("late latching"), so the pose has to be
        // predicted much less far ahead and small head movements don't overshoot.
        let lead = update.targetTimestamp - CACurrentMediaTime()
        let wait = lead - renderMargin
        if wait > 0.0005 { RenderLoop.sleep(until: update.targetTimestamp - renderMargin) }
        let now = CACurrentMediaTime()
        let target = update.targetPresentationTimestamp
        // macOS sometimes shows frames a refresh later than it promises, switching between the
        // two phases every few seconds. Predict for when frames are *actually* being shown.
        os_unfair_lock_lock(&lock)
        let presentOffset = presentOffsetEMA
        os_unfair_lock_unlock(&lock)
        let params = poseForTime(target + presentOffset)
        // Measure when frames really reach the screen versus when we sampled the pose.
        update.drawable.addPresentedHandler { [weak self] drawable in
            let shown = drawable.presentedTime
            guard shown > 0, let self else { return }
            os_unfair_lock_lock(&self.lock)
            self.latencySum += shown - now
            self.targetErrorSum += shown - target
            self.presentOffsetEMA += (min(max(shown - target, 0), 0.034) - self.presentOffsetEMA) * 0.25
            self.latencyCount += 1
            os_unfair_lock_unlock(&self.lock)
        }
        renderer.render(to: update.drawable, params: params, texture: textureProvider())

        os_unfair_lock_lock(&lock)
        if lastFrame > 0 {
            let gap = now - lastFrame
            worstGap = max(worstGap, gap)
            if gap > 1.5 / 120 { slowFrames += 1 }
        }
        lastFrame = now
        deadlineLeadMs = lead * 1000
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        os_unfair_lock_unlock(&lock)
    }

    /// Frames per second over the last second, and pacing since the previous call.
    func takeStats() -> (fps: Int, worstGapMs: Double, slowFrames: Int, deadlineLeadMs: Double,
                         poseToScreenMs: Double, targetErrorMs: Double) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let n = Double(max(latencyCount, 1))
        let result = (frameTimes.count, worstGap * 1000, slowFrames, deadlineLeadMs, latencySum / n * 1000, targetErrorSum / n * 1000)
        latencySum = 0
        targetErrorSum = 0
        latencyCount = 0
        worstGap = 0
        slowFrames = 0
        return result
    }
}
