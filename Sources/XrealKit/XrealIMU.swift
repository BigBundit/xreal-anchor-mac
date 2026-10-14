import Foundation
import IOKit
import IOKit.hid

/// One raw reading from the glasses' ICM-42688 IMU, in the sensor's own axes.
public struct IMUSample {
    /// Device timestamp in nanoseconds.
    public var timestamp: UInt64
    /// Angular velocity in degrees per second.
    public var gyro: SIMD3<Float>
    /// Acceleration in g.
    public var accel: SIMD3<Float>
    /// Sensor temperature in °C.
    public var temperature: Float
}

public enum XrealModel: UInt16, CaseIterable {
    case air = 0x0424
    case air2 = 0x0428
    case air2Pro = 0x0432
    case air2Ultra = 0x0426

    public var name: String {
        switch self {
        case .air: return "XREAL Air"
        case .air2: return "XREAL Air 2"
        case .air2Pro: return "XREAL Air 2 Pro"
        case .air2Ultra: return "XREAL Air 2 Ultra"
        }
    }

    var imuInterface: Int { self == .air2Ultra ? 2 : 3 }
    var mcuInterface: Int { self == .air2Ultra ? 0 : 4 }
}

public let xrealVendorID = 0x3318

/// Returns the USB interface number that a HID device hangs off, or -1.
func usbInterfaceNumber(of device: IOHIDDevice) -> Int {
    var service = IOHIDDeviceGetService(device)
    guard service != IO_OBJECT_NULL else { return -1 }
    IOObjectRetain(service)
    // Walk up the registry until we find an object that carries bInterfaceNumber.
    for _ in 0..<4 {
        if let n = IORegistryEntryCreateCFProperty(service, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber {
            IOObjectRelease(service)
            return n.intValue
        }
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        let kr = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else { return -1 }
        service = parent
    }
    IOObjectRelease(service)
    return -1
}

/// Framing used by both the IMU and MCU control channels:
/// [0xAA][crc32 LE x4][length LE x2][msgid][data...] where length = 3 + data.count and
/// the CRC covers the length, msgid and data bytes.
func xrealCommandPacket(msgID: UInt8, data: [UInt8], size: Int = 64) -> [UInt8] {
    let length = UInt16(3 + data.count)
    var body: [UInt8] = [UInt8(length & 0xff), UInt8(length >> 8), msgID]
    body += data
    let crc = CRC32.checksum(body)
    var packet: [UInt8] = [0xAA, UInt8(crc & 0xff), UInt8((crc >> 8) & 0xff), UInt8((crc >> 16) & 0xff), UInt8(crc >> 24)]
    packet += body
    if packet.count < size { packet += [UInt8](repeating: 0, count: size - packet.count) }
    return packet
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(b)) & 0xff)] }
        return ~crc
    }
}

/// Reads head-tracking data from XREAL Air-family glasses over IOKit HID.
/// Handles hot-plug: it keeps waiting for the glasses and restarts the stream when they reappear.
public final class XrealIMU {
    public var onSample: ((IMUSample) -> Void)?
    public var onConnectionChange: ((XrealModel?) -> Void)?

    public private(set) var model: XrealModel?

    private var manager: IOHIDManager?
    private var imuDevice: IOHIDDevice?
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
        t.name = "XrealIMU"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        if let device = imuDevice {
            send(device: device, msgID: 0x19, data: [0x00])
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            imuDevice = nil
        }
        if let rl = runLoop { CFRunLoopStop(rl) }
        thread = nil
        runLoop = nil
    }

    private func runThread() {
        runLoop = CFRunLoopGetCurrent()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: xrealVendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<XrealIMU>.fromOpaque(ctx).takeUnretainedValue().deviceAppeared(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<XrealIMU>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        CFRunLoopRun()
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func deviceAppeared(_ device: IOHIDDevice) {
        guard let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
              let m = XrealModel(rawValue: UInt16(pid)) else { return }
        let iface = usbInterfaceNumber(of: device)
        guard iface == m.imuInterface, imuDevice == nil else { return }

        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            NSLog("XrealIMU: failed to open IMU interface")
            return
        }
        imuDevice = device
        model = m
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 1024, { ctx, result, _, _, _, report, length in
            guard let ctx, result == kIOReturnSuccess else { return }
            Unmanaged<XrealIMU>.fromOpaque(ctx).takeUnretainedValue().handleReport(report, length: length)
        }, ctx)
        // Ask the glasses to start streaming IMU packets.
        send(device: device, msgID: 0x19, data: [0x01])
        onConnectionChange?(m)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let current = imuDevice, CFEqual(current, device) else { return }
        imuDevice = nil
        model = nil
        onConnectionChange?(nil)
    }

    @discardableResult
    private func send(device: IOHIDDevice, msgID: UInt8, data: [UInt8]) -> Bool {
        let packet = xrealCommandPacket(msgID: msgID, data: data)
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(packet[0]), packet, packet.count)
        if r != kIOReturnSuccess { NSLog("XrealIMU: SetReport failed 0x%x", r) }
        return r == kIOReturnSuccess
    }

    private func handleReport(_ p: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 64, p[0] == 0x01, p[1] == 0x02 else { return }

        func u32(_ o: Int) -> UInt32 { UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24 }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8) }
        func i24(_ o: Int) -> Int32 {
            var v = UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16
            if p[o + 2] & 0x80 != 0 { v |= 0xFF00_0000 }
            return Int32(bitPattern: v)
        }

        let temperature = Float(i16(2)) / 132.48 + 25
        let timestamp = UInt64(u32(4)) | UInt64(u32(8)) << 32

        let gm = Float(i16(12)), gd = Float(Int32(bitPattern: u32(14)))
        let am = Float(i16(27)), ad = Float(Int32(bitPattern: u32(29)))
        guard gd != 0, ad != 0 else { return }
        let gyro = SIMD3<Float>(Float(i24(18)), Float(i24(21)), Float(i24(24))) * gm / gd
        let accel = SIMD3<Float>(Float(i24(33)), Float(i24(36)), Float(i24(39))) * am / ad

        onSample?(IMUSample(timestamp: timestamp, gyro: gyro, accel: accel, temperature: temperature))
    }
}
