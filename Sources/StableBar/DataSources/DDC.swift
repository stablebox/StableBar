import CoreGraphics
import Foundation
import IOKit

/// An external display's own brightness over DDC/CI, VESA's commands over the display cable, as MonitorControl and
/// m1ddc send them on Apple silicon through IOKit's IOAVService. A display behind a dock, or on some Macs' built-in
/// HDMI port, doesn't answer.
struct DDC: @unchecked Sendable {
    static let brightness: UInt8 = 0x10

    /// The display's I2C address for DDC/CI, and the address that starts a command to it.
    private static let chip: UInt32 = 0x37
    private static let host: UInt32 = 0x51

    /// The display's IOAVService, which `PrivateAPI` calls are only made through.
    private let service: CFTypeRef

    /// "Set VCP feature" `code` to `value`.
    static func setPacket(_ code: UInt8, _ value: UInt16) -> [UInt8] {
        checksummed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// "Get VCP feature" `code`.
    static func getPacket(_ code: UInt8) -> [UInt8] {
        checksummed([0x82, 0x01, code])
    }

    /// A command's checksum covers the display's write address and the host's address before its bytes.
    private static func checksummed(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(0x6E ^ 0x51, ^)]
    }

    /// The value and the maximum a "Get VCP feature" reply gives for `code`: nil for a reply that's garbled, for
    /// another code, or that says the display doesn't support it. Some displays say 0 for the maximum, which means 100.
    static func reply(_ bytes: [UInt8], for code: UInt8) -> (value: UInt16, maximum: UInt16)? {
        guard bytes.count >= 11, bytes[0] == 0x6E, bytes[1] == 0x88, bytes[2] == 0x02, bytes[3] == 0, bytes[4] == code,
              bytes[10] == bytes[0..<10].reduce(0x50, ^) else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        return (UInt16(bytes[8]) << 8 | UInt16(bytes[9]), maximum == 0 ? 100 : maximum)
    }

    /// Blocking for about 70 ms, so callers go through `BlockingWork.run`. Displays drop some commands, so it sends each
    /// twice and asks up to four times.
    func read(_ code: UInt8) throws -> (value: UInt16, maximum: UInt16) {
        for _ in 0..<4 {
            try send(Self.getPacket(code))
            // DDC/CI gives a display 40 ms to answer.
            usleep(50_000)
            var answer = [UInt8](repeating: 0, count: 12)
            if PrivateAPI.avServiceReadI2C?(service, Self.chip, Self.host, &answer, UInt32(answer.count)) == 0,
               let reply = Self.reply(answer, for: code) {
                return reply
            }
        }
        throw CommandFailure(message: "The display doesn't answer DDC/CI.")
    }

    /// Blocking for about 70 ms, as the display needs between two commands.
    func write(_ code: UInt8, _ value: UInt16) throws {
        try send(Self.setPacket(code, value))
        usleep(50_000)
    }

    private func send(_ packet: [UInt8]) throws {
        var packet = packet
        for _ in 0..<2 {
            usleep(10_000)
            guard PrivateAPI.avServiceWriteI2C?(service, Self.chip, Self.host, &packet, UInt32(packet.count)) == 0 else {
                throw CommandFailure(message: "The display doesn't answer DDC/CI.")
            }
        }
    }

    /// The external `displays`' services. Each framebuffer in the registry names its display's maker, model and serial
    /// number, as CoreGraphics does, and the external AV service after it is that display's. Blocking: it walks the
    /// whole registry.
    static func services(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDC] {
        guard let create = PrivateAPI.avServiceCreateWithService, PrivateAPI.avServiceReadI2C != nil, PrivateAPI.avServiceWriteI2C != nil else {
            return [:]
        }
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var unclaimed = displays.filter { CGDisplayIsBuiltin($0) == 0 }
        var services: [CGDirectDisplayID: DDC] = [:]
        var framebuffer: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            switch name.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                framebuffer = attributes?["ProductAttributes"] as? [String: Any]
            case "DCPAVServiceProxy":
                guard IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                        == "External",
                      let product = framebuffer,
                      let display = unclaimed.first(where: { matches(product, $0) }),
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                services[display] = DDC(service: service)
                unclaimed.removeAll { $0 == display }
                framebuffer = nil
            default:
                break
            }
        }
        return services
    }

    /// Whether a framebuffer's product attributes describe `display`. A display without a serial number matches on its
    /// maker and model, so of two such twins the first found gets the first service.
    private static func matches(_ product: [String: Any], _ display: CGDirectDisplayID) -> Bool {
        guard product["LegacyManufacturerID"] as? Int == Int(CGDisplayVendorNumber(display)),
              product["ProductID"] as? Int == Int(CGDisplayModelNumber(display)) else { return false }
        let serial = CGDisplaySerialNumber(display)
        return serial == 0 || product["SerialNumber"] as? Int == Int(serial)
    }
}
