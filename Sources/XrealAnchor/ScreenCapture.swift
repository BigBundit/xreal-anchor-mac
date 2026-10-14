import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Metal
import os

/// Streams one display's pixels into Metal textures with ScreenCaptureKit.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "XrealAnchor.capture", qos: .userInteractive)

    private var lock = os_unfair_lock()
    private var latest: CVMetalTexture?
    private(set) var frameCount = 0

    var onError: ((Error) -> Void)?

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// The most recent frame, or nil before the first one arrives.
    var texture: MTLTexture? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return latest.flatMap { CVMetalTextureGetTexture($0) }
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, showsCursor: Bool) async throws {
        await stop()
        // A brand-new virtual display can take a moment to show up in the shareable content.
        var scDisplay: SCDisplay?
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let scDisplay else { throw CaptureError.displayNotFound }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = showsCursor
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let s = stream {
            stream = nil
            try? await s.stopCapture()
        }
        clearLatest()
    }

    private func clearLatest() {
        os_unfair_lock_lock(&lock)
        latest = nil
        os_unfair_lock_unlock(&lock)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        var cvTexture: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        guard let cvTexture else { return }
        os_unfair_lock_lock(&lock)
        latest = cvTexture
        frameCount += 1
        os_unfair_lock_unlock(&lock)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture stopped: \(error)")
        onError?(error)
    }

    enum CaptureError: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "ไม่พบจอเสมือนสำหรับจับภาพ" }
    }
}
