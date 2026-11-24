import Foundation
import Network
import SystemConfiguration

/// The Mac's addresses and a speed test, for the Quick toggles' Network details.
enum NetworkDetails {
    /// Answers with the public address it sees the request come from, as plain text.
    static let publicAddressService = URL(string: "https://api.ipify.org")!

    /// The IPv4 address of the interface macOS sends traffic through, and that interface's name, such as `en0`, whether
    /// it's Wi-Fi or Ethernet.
    static func localAddress() -> (interface: String, address: String)? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String else { return nil }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        for entry in sequence(first: first, next: { $0?.pointee.ifa_next }).compactMap({ $0?.pointee }) {
            guard String(cString: entry.ifa_name) == interface, let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            return (interface, host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        return nil
    }

    /// The router's IPv4 address on the network macOS sends traffic through.
    static func router() -> String? {
        (SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["Router"] as? String
    }

    /// Asks `publicAddressService`, only when the person asks for the address: it's a request to the internet.
    static func publicAddress() async throws -> String {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: publicAddressService)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              IPv4Address(text) != nil || IPv6Address(text) != nil else {
            throw CommandFailure(message: "api.ipify.org didn't answer with an address.")
        }
        return text
    }

    struct SpeedTest: Equatable, Sendable {
        /// Bits per second.
        var download: Double?
        var upload: Double?
        /// Round trips per minute under load, as macOS measures responsiveness.
        var responsiveness: Double?
    }

    /// Runs macOS's `networkQuality`, which downloads and uploads for about 20 seconds.
    static func speedTest() async throws -> SpeedTest {
        try speedTest(json: try await runCommand("/usr/bin/networkQuality", arguments: ["-c"], timeout: 90))
    }

    /// What `networkQuality -c` printed. Apple doesn't document its keys, so a missing one leaves that value out.
    static func speedTest(json: Data) throws -> SpeedTest {
        let result = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        return SpeedTest(download: (result["dl_throughput"] as? NSNumber)?.doubleValue, upload: (result["ul_throughput"] as? NSNumber)?.doubleValue,
                         responsiveness: (result["responsiveness"] as? NSNumber)?.doubleValue)
    }
}
