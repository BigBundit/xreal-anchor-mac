import Foundation
import Combine

enum TrackingMode: String, CaseIterable, Identifiable {
    /// The screen stays fixed in space.
    case anchored
    /// The screen stays put for small head movements and glides after you when you turn away.
    case follow
    /// The screen moves with your head, like plain glasses, but keeps all the other features.
    case headLocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anchored: return "ล็อคกับที่ (Anchored)"
        case .follow: return "ตามแบบนุ่มนวล (Smooth Follow)"
        case .headLocked: return "ติดตามหัว (Head-locked)"
        }
    }
}

struct ResolutionPreset: Identifiable, Hashable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var title: String {
        let ratio = Double(width) / Double(height)
        let label = ratio > 2 ? " · Ultrawide" : ""
        return "\(width) × \(height)\(label)"
    }
    var aspect: Float { Float(width) / Float(height) }

    static let all: [ResolutionPreset] = [
        .init(width: 1280, height: 720),
        .init(width: 1600, height: 900),
        .init(width: 1920, height: 1080),
        .init(width: 2560, height: 1440),
        .init(width: 2560, height: 1080),
        .init(width: 3440, height: 1440),
        .init(width: 3840, height: 1080),
    ]
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var mode: TrackingMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    /// Horizontal angle the virtual screen covers, in degrees.
    @Published var screenAngle: Double { didSet { d.set(screenAngle, forKey: "screenAngle") } }
    @Published var curved: Bool { didSet { d.set(curved, forKey: "curved") } }
    @Published var resolutionID: String { didSet { d.set(resolutionID, forKey: "resolutionID") } }
    @Published var hiDPI: Bool { didSet { d.set(hiDPI, forKey: "hiDPI") } }
    /// Extra motion prediction on top of the measured time until the frame is shown, ms.
    @Published var predictionMs: Double { didSet { d.set(predictionMs, forKey: "extraPredictionMsV2") } }
    /// How far the lenses sit in front of the neck pivot, relative to the screen distance.
    @Published var lensOffset: Double { didSet { d.set(lensOffset, forKey: "lensOffset") } }
    /// Smooth out tiny jitter while the head is (nearly) still.
    @Published var stabilize: Bool { didSet { d.set(stabilize, forKey: "stabilize") } }
    /// Smooth follow kicks in once you look further than this from the screen, degrees.
    @Published var followThreshold: Double { didSet { d.set(followThreshold, forKey: "followThreshold") } }
    @Published var followSpeed: Double { didSet { d.set(followSpeed, forKey: "followSpeed") } }
    /// Diagonal field of view of the glasses, degrees.
    @Published var glassesFOV: Double { didSet { d.set(glassesFOV, forKey: "glassesFOVv2") } }
    /// Vertical offset of the screen relative to eye level when recentering, degrees.
    @Published var verticalOffset: Double { didSet { d.set(verticalOffset, forKey: "verticalOffset") } }
    @Published var keepLevel: Bool { didSet { d.set(keepLevel, forKey: "keepLevel") } }
    @Published var autoStart: Bool { didSet { d.set(autoStart, forKey: "autoStart") } }
    @Published var buttonRecenter: Bool { didSet { d.set(buttonRecenter, forKey: "buttonRecenter") } }
    @Published var guardCursor: Bool { didSet { d.set(guardCursor, forKey: "guardCursor") } }
    @Published var showCursor: Bool { didSet { d.set(showCursor, forKey: "showCursor") } }
    @Published var invertYaw: Bool { didSet { d.set(invertYaw, forKey: "invertYaw") } }
    @Published var invertPitch: Bool { didSet { d.set(invertPitch, forKey: "invertPitch") } }

    /// Shows a grid in the glasses while tuning stability. Not persisted.
    @Published var tuningGrid = false

    var resolution: ResolutionPreset {
        ResolutionPreset.all.first { $0.id == resolutionID } ?? ResolutionPreset.all[2]
    }

    private init() {
        d.register(defaults: [
            "mode": TrackingMode.anchored.rawValue,
            "screenAngle": 36.0,
            "curved": false,
            "resolutionID": "1920x1080",
            "hiDPI": true,
            "extraPredictionMsV2": 2.0,
            "lensOffset": 0.05,
            "stabilize": true,
            "followThreshold": 18.0,
            "followSpeed": 3.0,
            "glassesFOVv2": 45.0,
            "verticalOffset": 0.0,
            "keepLevel": false,
            "autoStart": true,
            "buttonRecenter": false,
            "guardCursor": true,
            "showCursor": true,
            "invertYaw": false,
            "invertPitch": false,
        ])
        mode = TrackingMode(rawValue: d.string(forKey: "mode") ?? "") ?? .anchored
        screenAngle = d.double(forKey: "screenAngle")
        curved = d.bool(forKey: "curved")
        resolutionID = d.string(forKey: "resolutionID") ?? "1920x1080"
        hiDPI = d.bool(forKey: "hiDPI")
        predictionMs = d.double(forKey: "extraPredictionMsV2")
        lensOffset = d.double(forKey: "lensOffset")
        stabilize = d.bool(forKey: "stabilize")
        followThreshold = d.double(forKey: "followThreshold")
        followSpeed = d.double(forKey: "followSpeed")
        glassesFOV = d.double(forKey: "glassesFOVv2")
        verticalOffset = d.double(forKey: "verticalOffset")
        keepLevel = d.bool(forKey: "keepLevel")
        autoStart = d.bool(forKey: "autoStart")
        buttonRecenter = d.bool(forKey: "buttonRecenter")
        guardCursor = d.bool(forKey: "guardCursor")
        showCursor = d.bool(forKey: "showCursor")
        invertYaw = d.bool(forKey: "invertYaw")
        invertPitch = d.bool(forKey: "invertPitch")
    }
}
