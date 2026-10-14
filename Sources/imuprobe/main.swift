import Foundation
import XrealKit
import simd

// Prints per-second gyro mean/variance and accel so the protocol, axes and noise can be checked.
let imu = XrealIMU()
var n = 0
var sum = SIMD3<Float>(repeating: 0), sumSq = SIMD3<Float>(repeating: 0), accelSum = SIMD3<Float>(repeating: 0)
var start: UInt64 = 0

imu.onConnectionChange = { model in print("connected:", model?.name ?? "none") }
let tracker = HeadTracker()
let track = CommandLine.arguments.contains("track")
// `imuprobe <seconds> record <file.csv>` dumps raw samples for offline filter tuning.
let recordPath: String? = CommandLine.arguments.firstIndex(of: "record").flatMap {
    CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
}
var recordLines: [String] = []
var lastTrackPrint: UInt64 = 0
imu.onSample = { s in
    if recordPath != nil {
        recordLines.append("\(s.timestamp),\(s.gyro.x),\(s.gyro.y),\(s.gyro.z),\(s.accel.x),\(s.accel.y),\(s.accel.z)")
        return
    }
    if track {
        tracker.process(s)
        if s.timestamp - lastTrackPrint > 500_000_000 {
            lastTrackPrint = s.timestamp
            let st = tracker.snapshot()
            let (yaw, pitch) = st.orientation.yawPitch
            print(String(format: "yaw % 7.2f  pitch % 6.2f  calibrated=%@  rate=%.0f", yaw * 180 / .pi, pitch * 180 / .pi,
                         st.calibrated ? "yes" : "no", st.sampleRate) + "  " + tracker.debugInfo)
        }
        return
    }
    if start == 0 { start = s.timestamp }
    n += 1; sum += s.gyro; sumSq += s.gyro * s.gyro; accelSum += s.accel
    if s.timestamp - start >= 1_000_000_000 {
        let c = Float(n), mean = sum / c, variance = sumSq / c - mean * mean, a = accelSum / c
        print(String(format: "n=%4d gyro mean % 6.2f % 6.2f % 6.2f  var %.3f %.3f %.3f  accel % 5.2f % 5.2f % 5.2f  %.1fC",
                     n, mean.x, mean.y, mean.z, variance.x, variance.y, variance.z, a.x, a.y, a.z, s.temperature))
        n = 0; sum = .zero; sumSq = .zero; accelSum = .zero; start = s.timestamp
    }
}
imu.start()
let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 5 : 5
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
imu.stop()
if let recordPath {
    try? (["t,gx,gy,gz,ax,ay,az"] + recordLines).joined(separator: "\n").write(toFile: recordPath, atomically: true, encoding: .utf8)
    print("recorded \(recordLines.count) samples to \(recordPath)")
}
