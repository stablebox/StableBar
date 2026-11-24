import CoreWLAN

/// A network a Wi-Fi scan found, as the Quick toggles' Wi-Fi card lists it.
struct WiFiNetwork: Equatable, Sendable, Identifiable {
    let ssid: String
    /// dBm.
    let rssi: Int
    let secure: Bool
    /// Whether this Mac saved it.
    let known: Bool

    var id: String { ssid }

    /// 0 at -100 dBm and below, 1 at -50 dBm and above, as the `wifi` provider reports `values.signal`.
    var signal: Double { min(1, max(0, Double(rssi + 100) / 50)) }

    /// The networks to list from what a scan `found`: each name once, at its strongest access point's signal, without
    /// the network joined, known networks first, then the strongest.
    static func list(_ found: [WiFiNetwork], joined: String?) -> [WiFiNetwork] {
        var strongest: [String: WiFiNetwork] = [:]
        for network in found where network.ssid != joined && network.rssi > strongest[network.ssid]?.rssi ?? .min {
            strongest[network.ssid] = network
        }
        return strongest.values.sorted { first, second in
            if first.known != second.known { return first.known }
            if first.rssi != second.rssi { return first.rssi > second.rssi }
            return first.ssid < second.ssid
        }
    }

    /// The list after a new scan `found` networks: those `shown` still in range keep their place with their new signal,
    /// those out of range go, and new ones follow, so the list doesn't jump while it's read.
    static func merged(_ shown: [WiFiNetwork], with found: [WiFiNetwork], joined: String?) -> [WiFiNetwork] {
        let fresh = list(found, joined: joined)
        let kept = shown.compactMap { old in fresh.first { $0.ssid == old.ssid } }
        return kept + fresh.filter { new in !kept.contains { $0.ssid == new.ssid } }
    }
}

/// Joining a network from the Quick toggles' Wi-Fi card: whether it asks for the password, joins, or says why it
/// couldn't. CoreWLAN never joins with the password this Mac saved, so a secured network always asks for it.
struct WiFiJoin: StateMachine, Equatable {
    enum Mode: Equatable {
        case idle
        /// Asks for the network's password, `wrong` after one that didn't work.
        case asking(String, wrong: Bool)
        case joining(String, secured: Bool)
        case failed(String, message: String)
    }

    enum Event: Equatable {
        case choose(WiFiNetwork)
        case submit(password: String)
        case cancel
        case joined
        case wrongPassword
        case failed(message: String)

        /// The event for a join that threw `error`. A wrong password fails the WPA handshake: the access point rejects
        /// the key made from it, or ignores it until the handshake times out.
        static func failure(_ error: Error) -> Event {
            let error = error as NSError
            guard error.domain == CWErrorDomain,
                  [CWErr.cwInvalidPMKErr.rawValue, CWErr.cwSupplicantTimeoutErr.rawValue].contains(error.code) else {
                return .failed(message: errorMessage(error))
            }
            return .wrongPassword
        }
    }

    enum Effect: Equatable {
        case join(String, password: String?)
    }

    private(set) var mode = Mode.idle

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .choose(network):
            if case .joining = mode { return [] }
            if network.secure {
                mode = .asking(network.ssid, wrong: false)
                return []
            }
            mode = .joining(network.ssid, secured: false)
            return [.join(network.ssid, password: nil)]
        case let .submit(password):
            guard case let .asking(ssid, _) = mode else { return [] }
            mode = .joining(ssid, secured: true)
            return [.join(ssid, password: password)]
        case .cancel:
            mode = .idle
        case .joined:
            if case .joining = mode { mode = .idle }
        case .wrongPassword:
            guard case let .joining(ssid, _) = mode else { return [] }
            mode = .asking(ssid, wrong: true)
        case let .failed(message):
            guard case let .joining(ssid, _) = mode else { return [] }
            mode = .failed(ssid, message: message)
        }
        return []
    }
}
