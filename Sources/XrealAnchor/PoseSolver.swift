import Foundation
import QuartzCore
import simd
import os
import XrealKit

/// The settings the render thread needs, copied out of `Settings` so the render thread
/// never touches main-thread state.
struct PoseConfig {
    var mode: TrackingMode = .anchored
    var extraPredictionMs: Float = 6
    var followThreshold: Float = 18
    var followSpeed: Float = 3
    var keepLevel = false
    var verticalOffset: Float = 0
    var invertYaw = false
    var invertPitch = false
    var stabilize = true
    var fov: Float = 46
    var screenAngle: Float = 36
    var curved = false
    var lensOffset: Float = 0.05
    var showGrid = false

    init() {}

    init(_ s: Settings) {
        mode = s.mode
        extraPredictionMs = Float(s.predictionMs)
        followThreshold = Float(s.followThreshold)
        followSpeed = Float(s.followSpeed)
        keepLevel = s.keepLevel
        verticalOffset = Float(s.verticalOffset)
        invertYaw = s.invertYaw
        invertPitch = s.invertPitch
        stabilize = s.stabilize
        fov = Float(s.glassesFOV)
        screenAngle = Float(s.screenAngle)
        curved = s.curved
        lensOffset = Float(s.lensOffset)
        showGrid = s.tuningGrid
    }
}

/// Turns the tracked head orientation into the per-frame view rotation. Thread-safe: the
/// render thread asks for frames while the main thread recenters and changes settings.
final class PoseSolver {
    private let tracker: HeadTracker
    private var lock = os_unfair_lock()
    private var config = PoseConfig()
    private var anchor = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var following = false
    private var lastPresent: CFTimeInterval = 0
    private var stabilized: simd_quatf?
    /// The most recent prediction horizon, for diagnostics.
    private(set) var lastLookAheadMs: Float = 0

    init(tracker: HeadTracker) {
        self.tracker = tracker
    }

    func update(_ newConfig: PoseConfig) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        config = newConfig
    }

    /// Places the screen straight ahead of where the wearer is looking now.
    func recenter() {
        let q = tracker.snapshot().orientation
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var (yaw, pitch) = q.yawPitch
        if config.keepLevel { pitch = 0 }
        pitch += config.verticalOffset * .pi / 180
        anchor = .fromYawPitch(yaw: yaw, pitch: pitch)
        following = false
        stabilized = nil
    }

    /// Moves the screen around the wearer: positive yaw is to the left, positive pitch is up.
    func nudge(yawDegrees: Float, pitchDegrees: Float) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        anchor = simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0)) * anchor
        anchor = simd_normalize(anchor * simd_quatf(angle: pitchDegrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0)))
        following = false
    }

    /// Head yaw/pitch relative to the screen, degrees, for the status read-out.
    func relativeYawPitch() -> (Float, Float) {
        let q = tracker.snapshot().orientation
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let (yaw, pitch) = (anchor.inverse * q).yawPitch
        return (yaw * 180 / .pi, pitch * 180 / .pi)
    }

    /// The view for a frame that will reach the glasses at `presentTime` (CACurrentMediaTime clock).
    func frame(presentTime: CFTimeInterval) -> FrameParams {
        let state = tracker.snapshot()
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }

        let dt = Float(lastPresent == 0 ? 1.0 / 120 : min(max(presentTime - lastPresent, 0), 0.1))
        lastPresent = presentTime

        // Predict the head pose for the moment this frame's top row is on screen: from the time
        // the newest IMU sample arrived, through (measured) presentation, plus the glasses' own delay.
        var head = state.orientation
        let w = state.angularVelocity
        let speed = simd_length(w)
        let sampleAge = state.sampleHostTime > 0 ? presentTime - state.sampleHostTime : presentTime - CACurrentMediaTime()
        let lookAhead = Float(min(max(sampleAge, 0), 0.04)) + config.extraPredictionMs / 1000
        lastLookAheadMs = lookAhead * 1000
        if speed > 1e-4, lookAhead > 0 {
            head = simd_normalize(head * simd_quatf(angle: speed * min(lookAhead, 0.05), axis: w / speed))
        }

        // One-euro style smoothing: strong when (nearly) still to kill shimmer, none when moving.
        if config.stabilize, let previous = stabilized {
            let cutoff: Float = 3 + 200 * speed
            let alpha = 1 - exp(-2 * .pi * cutoff * dt)
            head = simd_slerp(previous, head, alpha)
        }
        stabilized = head

        var rotation: simd_quatf
        switch config.mode {
        case .headLocked:
            rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        case .anchored:
            rotation = anchor.inverse * head
        case .follow:
            let (yaw, pitch) = head.yawPitch
            let target = simd_quatf.fromYawPitch(yaw: yaw, pitch: config.keepLevel ? anchor.yawPitch.pitch : pitch)
            let offAngle = acos(max(-1, min(1, simd_dot(anchor.forward, head.forward)))) * 180 / .pi
            if offAngle > config.followThreshold { following = true }
            if following {
                let t = 1 - exp(-config.followSpeed * dt)
                anchor = simd_slerp(anchor, target, t)
                if offAngle < 1.5 { following = false }
            }
            rotation = anchor.inverse * head
        }

        var m = simd_float3x3(rotation)
        if config.invertYaw {
            let f = simd_float3x3(diagonal: SIMD3(-1, 1, 1)); m = f * m * f
        }
        if config.invertPitch {
            let f = simd_float3x3(diagonal: SIMD3(1, -1, 1)); m = f * m * f
        }
        let moving = config.mode != .headLocked
        return FrameParams(rotation: m, fovDiagonal: config.fov, screenAngle: config.screenAngle, curved: config.curved,
                           angularVelocity: moving ? w : .zero, scanlineSpan: moving ? 0.008 : 0,
                           lensOffset: moving ? config.lensOffset : 0, showGrid: config.showGrid)
    }
}
