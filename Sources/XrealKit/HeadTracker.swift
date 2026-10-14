import Foundation
import simd
import os

/// Turns raw IMU samples into a head orientation.
///
/// Frames: the body frame is the usual graphics convention (x right, y up, z towards the back
/// of the head, so the wearer looks down -z). The world frame shares that convention with y
/// aligned to gravity. Pitch and roll are corrected from the accelerometer (Mahony-style);
/// yaw is pure gyro integration, so the gyro bias is estimated whenever the head is still.
public final class HeadTracker {
    public struct State {
        /// Rotation from body to world.
        public var orientation: simd_quatf
        /// Bias-corrected angular velocity in the body frame, rad/s, lightly low-passed
        /// (~5 ms) so motion prediction does not amplify sensor noise.
        public var angularVelocity: SIMD3<Float>
        /// True once a gyro bias estimate exists.
        public var calibrated: Bool
        /// Progress of an explicit calibration in [0, 1], or nil when none is running.
        public var calibrationProgress: Float?
        public var temperature: Float
        public var sampleRate: Float
        /// When the latest sample arrived, on the same clock as CACurrentMediaTime (seconds).
        public var sampleHostTime: TimeInterval
    }

    /// Strength of the accelerometer tilt correction (rad/s per unit error). It is scaled
    /// down while the head moves, because head acceleration then corrupts the gravity reading.
    public var tiltGain: Float = 0.3

    private var lock = os_unfair_lock()
    private var q = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var omega = SIMD3<Float>(repeating: 0)
    private var bias = SIMD3<Float>(repeating: 0)
    private var hasBias = false
    private var initialized = false
    private var lastTimestamp: UInt64 = 0
    private var temperature: Float = 0
    private var lastHostTime: TimeInterval = 0

    // Bias tracking. Per-sample gyro noise is large (~0.6 dps) and a worn headset is never
    // perfectly still, so motion is judged on 100-sample block means:
    //  * on a table, block means agree within ~0.1 dps -> trust the window strongly;
    //  * on a head, calm stretches still average out to the bias -> nudge it slowly.
    private let blockSize = 100
    private var blockCount = 0
    private var blockGyro = SIMD3<Float>(repeating: 0)
    private var blockAccel = SIMD3<Float>(repeating: 0)
    private var previousBlockAccel: SIMD3<Float>?
    private var calmBlocks = 0
    private var calmSum = SIMD3<Float>(repeating: 0)
    private var recentMeans: [SIMD3<Float>] = []
    public private(set) var debugInfo = ""

    // Explicit calibration (glasses lying still on a table).
    private let calibrationSamples = 3000
    private var calibrating = false
    private var calCount = 0
    private var calSum = SIMD3<Float>(repeating: 0)

    // Sample rate measurement.
    private var rateCount = 0
    private var rateStart: UInt64 = 0
    private var sampleRate: Float = 0

    public init() {}

    public func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        initialized = false
    }

    /// Starts a 3-second calibration. The glasses must stay completely still meanwhile.
    public func startCalibration() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        calibrating = true
        calCount = 0
        calSum = .zero
    }

    public func snapshot() -> State {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return State(
            orientation: q,
            angularVelocity: omega,
            calibrated: hasBias,
            calibrationProgress: calibrating ? Float(calCount) / Float(calibrationSamples) : nil,
            temperature: temperature,
            sampleRate: sampleRate,
            sampleHostTime: lastHostTime
        )
    }

    /// Maps the IMU's axes (x left, y back, z up) to the body frame (x right, y up, z back).
    @inline(__always) static func toBody(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-v.x, v.z, v.y)
    }

    public func process(_ sample: IMUSample) {
        let gyroDeg = HeadTracker.toBody(sample.gyro)
        let accel = HeadTracker.toBody(sample.accel)

        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        temperature = sample.temperature
        // systemUptime and CACurrentMediaTime both count mach absolute time in seconds.
        lastHostTime = ProcessInfo.processInfo.systemUptime

        rateCount += 1
        if rateStart == 0 { rateStart = sample.timestamp }
        if sample.timestamp &- rateStart > 1_000_000_000 {
            sampleRate = Float(rateCount) * 1e9 / Float(sample.timestamp &- rateStart)
            rateCount = 0
            rateStart = sample.timestamp
        }

        if calibrating {
            calSum += gyroDeg
            calCount += 1
            if calCount >= calibrationSamples {
                bias = calSum / Float(calCount)
                hasBias = true
                calibrating = false
                resetRest()
            }
        } else {
            trackRest(gyroDeg: gyroDeg, accel: accel)
        }

        guard initialized else {
            q = HeadTracker.levelOrientation(accel: accel)
            lastTimestamp = sample.timestamp
            initialized = true
            return
        }

        var dt = Float(Double(sample.timestamp &- lastTimestamp) / 1e9)
        lastTimestamp = sample.timestamp
        if !(dt > 0 && dt < 0.05) { dt = 0.001 }

        var w = (gyroDeg - bias) * (.pi / 180)
        omega += (w - omega) * min(1, dt / 0.005)

        // Accelerometer tilt correction, weighted by how much the reading looks like pure gravity.
        let aNorm = simd_length(accel)
        let gravityLikeness = max(0, 1 - abs(aNorm - 1) / 0.08)
        let speed = simd_length(w)
        let stillness = 1 / (1 + (speed / 0.3) * (speed / 0.3))
        let gain = tiltGain * gravityLikeness * stillness
        if gain > 0 {
            let measuredUp = accel / aNorm
            let estimatedUp = q.inverse.act(SIMD3<Float>(0, 1, 0))
            w += gain * simd_cross(measuredUp, estimatedUp)
        }

        let angle = simd_length(w) * dt
        if angle > 1e-9 {
            q = simd_normalize(q * simd_quatf(angle: angle, axis: simd_normalize(w)))
        }
    }

    // MARK: - Bias tracking

    private func resetRest() {
        blockCount = 0
        blockGyro = .zero
        blockAccel = .zero
        previousBlockAccel = nil
        calmBlocks = 0
        calmSum = .zero
        recentMeans.removeAll(keepingCapacity: true)
    }

    /// Re-estimates the gyro bias whenever the glasses are (nearly) still.
    private func trackRest(gyroDeg: SIMD3<Float>, accel: SIMD3<Float>) {
        blockGyro += gyroDeg
        blockAccel += accel
        blockCount += 1
        guard blockCount >= blockSize else { return }

        let gyroMean = blockGyro / Float(blockCount)
        let accelMean = blockAccel / Float(blockCount)
        blockCount = 0
        blockGyro = .zero
        blockAccel = .zero

        let accelJump = previousBlockAccel.map { simd_length(accelMean - $0) } ?? 0
        previousBlockAccel = accelMean
        let deviation = simd_reduce_max(simd_abs(gyroMean - bias))
        let calm = deviation < (hasBias ? 1.5 : 4.0) && accelJump < 0.02

        guard calm else {
            calmBlocks = 0
            calmSum = .zero
            recentMeans.removeAll(keepingCapacity: true)
            return
        }
        calmBlocks += 1
        calmSum += gyroMean
        recentMeans.append(gyroMean)
        if recentMeans.count > 8 { recentMeans.removeFirst() }

        if !hasBias {
            // First estimate: three calm seconds.
            if calmBlocks >= 30 {
                bias = calmSum / Float(calmBlocks)
                hasBias = true
            }
        } else if recentMeans.count == 8 {
            let mean = recentMeans.reduce(SIMD3<Float>(repeating: 0), +) / 8
            let spread = recentMeans.map { simd_reduce_max(simd_abs($0 - mean)) }.max() ?? .infinity
            if spread < 0.3 {
                // Lying still: the window mean is an excellent estimate.
                bias = bias * 0.8 + mean * 0.2
                recentMeans.removeAll(keepingCapacity: true)
            } else if calmBlocks >= 20 {
                // Worn but calm: follow slowly (time constant ~5 s of calm).
                bias += (gyroMean - bias) * 0.02
            }
        }
        debugInfo = String(format: "calm %d dev %.2f bias %.2f %.2f %.2f", calmBlocks, deviation, bias.x, bias.y, bias.z)
    }

    /// The current gyro bias in degrees per second (body frame), for persisting between runs.
    public var gyroBias: SIMD3<Float>? {
        get {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            return hasBias ? bias : nil
        }
        set {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            if let newValue { bias = newValue; hasBias = true }
        }
    }

    /// An orientation whose up axis matches gravity, with zero yaw.
    static func levelOrientation(accel: SIMD3<Float>) -> simd_quatf {
        let up = simd_length(accel) > 0.1 ? simd_normalize(accel) : SIMD3<Float>(0, 1, 0)
        // Rotation taking the body-frame up vector onto world up.
        return simd_quatf(from: up, to: SIMD3<Float>(0, 1, 0))
    }
}

public extension simd_quatf {
    /// The direction the wearer is looking, in world coordinates.
    var forward: SIMD3<Float> { act(SIMD3<Float>(0, 0, -1)) }

    /// Yaw (around world y) and pitch (around the resulting x) of the forward vector, radians.
    var yawPitch: (yaw: Float, pitch: Float) {
        let f = forward
        return (atan2(-f.x, -f.z), asin(max(-1, min(1, f.y))))
    }

    static func fromYawPitch(yaw: Float, pitch: Float) -> simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }
}
