import Foundation
import IOKit
import IOKit.hid

/// Listens to the glasses' MCU channel for button presses. It never writes to the device,
/// so it cannot change firmware state.
public final class XrealMCU {
    public enum Button: Equatable {
        case displayToggle(on: Bool)
        case brightnessUp(level: Int)
        case brightnessDown(level: Int)
        case other(code: Int)
    }

    public var onButton: ((Button) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)

    public init() {}

    deinit {
        stop()
        reportBuffer.deallocate()
    }

    public func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.runThread() }
        t.name = "XrealMCU"
        thread = t
        t.start()
    }

    public func stop() {
        if let d = device { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        if let rl = runLoop { CFRunLoopStop(rl) }
        runLoop = nil
        thread = nil
    }

    private func runThread() {
        runLoop = CFRunLoopGetCurrent()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: xrealVendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<XrealMCU>.fromOpaque(ctx).takeUnretainedValue().deviceAppeared(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<XrealMCU>.fromOpaque(ctx).takeUnretainedValue()
            if let d = me.device, CFEqual(d, device) { me.device = nil }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        CFRunLoopRun()
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func deviceAppeared(_ d: IOHIDDevice) {
        guard let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int,
              let m = XrealModel(rawValue: UInt16(pid)),
              usbInterfaceNumber(of: d) == m.mcuInterface, device == nil,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = d
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, reportBuffer, 1024, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess else { return }
            Unmanaged<XrealMCU>.fromOpaque(ctx).takeUnretainedValue().handle(report, length: length)
        }, ctx)
    }

    // Packet: [0xFD][crc x4][len x2][timestamp x8][msgid x2][reserved x5][data...]
    private func handle(_ p: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 32, p[0] == 0xFD else { return }
        let msgID = UInt16(p[15]) | UInt16(p[16]) << 8
        guard msgID == 0x6C05 else { return }
        let virt = Int(p[22 + 4]), value = Int(p[22 + 8])
        let button: Button
        switch virt {
        case 0x1: button = .displayToggle(on: value != 0)
        case 0x6: button = .brightnessUp(level: value)
        case 0x7: button = .brightnessDown(level: value)
        default: button = .other(code: virt)
        }
        onButton?(button)
    }
}
