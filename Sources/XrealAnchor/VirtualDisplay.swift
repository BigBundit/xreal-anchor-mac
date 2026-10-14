import Foundation
import CoreGraphics
import CVirtualDisplay

/// An extra monitor that only exists in software. macOS treats it like any other display;
/// we capture it and draw it into the glasses.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let preset: ResolutionPreset
    let hiDPI: Bool

    var displayID: CGDirectDisplayID { display.displayID }

    init?(preset: ResolutionPreset, hiDPI: Bool) {
        self.preset = preset
        self.hiDPI = hiDPI
        let scale = hiDPI ? 2 : 1

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "XREAL Anchor"
        descriptor.maxPixelsWide = UInt32(preset.width * scale)
        descriptor.maxPixelsHigh = UInt32(preset.height * scale)
        // A 27"-class physical size keeps macOS's default UI scale sensible.
        let widthMM = 600.0 * Double(preset.aspect) / (16.0 / 9.0)
        descriptor.sizeInMillimeters = CGSize(width: widthMM, height: widthMM / Double(preset.aspect))
        descriptor.vendorID = 0x3318
        descriptor.productID = 0xA0C4
        descriptor.serialNum = UInt32(preset.width * 10 + (hiDPI ? 1 : 0))
        descriptor.terminationHandler = { _, _ in }

        display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // Modes are listed in points. With hiDPI on (and maxPixels at 2x) macOS adds a
        // "looks like preset" variant backed by twice the pixels; ensureHiDPIMode selects it.
        let w = UInt32(preset.width), h = UInt32(preset.height)
        settings.modes = [
            CGVirtualDisplayMode(width: w, height: h, refreshRate: 120),
            CGVirtualDisplayMode(width: w, height: h, refreshRate: 60),
        ]
        guard display.apply(settings) else { return nil }
    }

    /// Makes sure the display runs at "looks like preset" with a 2x backing store.
    func ensureHiDPIMode() {
        guard hiDPI else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
        if let current = CGDisplayCopyDisplayMode(displayID), current.pixelWidth == preset.width * 2 { return }
        guard let target = modes.filter({ $0.width == preset.width && $0.pixelWidth == preset.width * 2 })
            .max(by: { $0.refreshRate < $1.refreshRate }) else {
            Log.info("no HiDPI mode; available: \(modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth)" })")
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("selected HiDPI mode \(target.width)x\(target.height) px \(target.pixelWidth)x\(target.pixelHeight): \(result.rawValue)")
    }

    /// Size of the display's backing store in pixels, which is what we capture.
    var pixelSize: (width: Int, height: Int) {
        // CoreGraphics' per-process display cache can lag behind a freshly created
        // display, so derive the size from what we asked for.
        let scale = hiDPI ? 2 : 1
        return (preset.width * scale, preset.height * scale)
    }
}
