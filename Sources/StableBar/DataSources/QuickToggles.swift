import AppKit
import CoreBluetooth
import CoreWLAN

/// What the Quick toggles' panel shows and changes, for all of StableBar: each toggle's state while the panel is open,
/// the displays, Keep awake, what the tools just did, the Wi-Fi networks nearby and the Mac's addresses. There is one,
/// since Keep awake, the displays' dimming and the camera mirror outlive the panel.
@MainActor @Observable
final class QuickToggles {
    /// Made on first use: setting it, as a scene does, reads nothing from the Mac.
    static var shared: QuickToggles {
        get {
            if let existing { return existing }
            let toggles = QuickToggles()
            existing = toggles
            return toggles
        }
        set { existing = newValue }
    }
    private(set) static var existing: QuickToggles?

    /// Each toggle's state. A toggle this Mac can't change is missing, and its tile hides.
    private(set) var states: [QuickTile: Bool] = [:]
    let displays: DisplayControls
    /// Night Shift's warmth, from 0 to 1; nil on a Mac without Night Shift.
    private(set) var nightShiftStrength: Double?
    /// The interface macOS sends traffic through and its address, the public address once asked for, and the last speed
    /// test.
    private(set) var localAddress: (interface: String, address: String)?
    private(set) var publicAddress: String?
    private(set) var fetchesPublicAddress = false
    private(set) var speedTest: NetworkDetails.SpeedTest?
    private(set) var testsSpeed = false
    /// The network the public address and the speed test are for.
    @ObservationIgnored private var network: [String?] = []
    let camera = CameraMirror()
    /// Whether macOS lets StableBar turn Bluetooth on and off, which it asks the first time Bluetooth's button is clicked.
    private(set) var bluetoothAccess = CBManagerAuthorization.notDetermined
    let keepAwake: KeepAwake
    /// The color the color picker just copied, in sRGB, for a few seconds.
    private(set) var pickedColor: NSColor?
    /// The tool that just did its job, whose button shows a checkmark for a moment.
    private(set) var done: QuickTile?
    /// The volumes Eject Disks ejects, read as the panel opens.
    private(set) var ejectable: [DiskVolume] = []
    /// The networks nearby, from the last scan or CoreWLAN's, nil before either.
    private(set) var networks: [WiFiNetwork]?
    private(set) var scanning = false
    private(set) var join = WiFiJoin()
    /// Why the last change failed.
    private(set) var error: String?
    /// The toggles and actions under way, whose tiles keep what they show until they're done.
    private(set) var running: Set<QuickTile> = []
    /// Whether it reads and changes the Mac, which a scene's sample doesn't.
    @ObservationIgnored private var acts = true
    /// The tile whose details a scene draws open.
    @ObservationIgnored private(set) var opensExpanded: QuickTile?

    init() {
        keepAwake = KeepAwake()
        displays = DisplayControls()
        read()
    }

    /// Quick toggles showing these, which never read or change the Mac, for drawing scenes.
    init(sample states: [QuickTile: Bool], displays: DisplayControls, nightShiftStrength: Double?,
         keepAwake: KeepAwakeState, pickedColor: NSColor?, ejectable: [DiskVolume], networks: [WiFiNetwork]?, scanning: Bool,
         localAddress: (interface: String, address: String)?, publicAddress: String?, speedTest: NetworkDetails.SpeedTest?,
         expanded: QuickTile?) {
        self.states = states
        self.displays = displays
        self.nightShiftStrength = nightShiftStrength
        self.localAddress = localAddress
        self.publicAddress = publicAddress
        self.speedTest = speedTest
        bluetoothAccess = .allowedAlways
        self.keepAwake = KeepAwake(sample: keepAwake)
        self.pickedColor = pickedColor
        self.ejectable = ejectable
        self.networks = networks
        self.scanning = scanning
        opensExpanded = expanded
        acts = false
    }

    /// Reads every toggle now and each second after, until the panel closes and cancels it: macOS posts nothing when
    /// most of them change.
    func follow() async {
        guard acts else { return }
        error = nil
        readEjectable()
        displays.read()
        // A display plugged in or out, or given another resolution elsewhere.
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                              queue: .main) { [displays] _ in
            MainActor.assumeIsolated { displays.read() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        while !Task.isCancelled {
            read()
            displays.readBuiltIn()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func read() {
        var states: [QuickTile: Bool] = [
            .darkMode: Self.preference("AppleInterfaceStyle", in: kCFPreferencesAnyApplication as String) == "Dark",
            .dockAutohide: Self.flag("autohide", in: "com.apple.dock") ?? false,
            .desktopIcons: !(Self.flag("CreateDesktop", in: "com.apple.finder") ?? true),
            .hiddenFiles: Self.flag("AppleShowAllFiles", in: "com.apple.finder") ?? false
        ]
        states[.nightShift] = PrivateAPI.nightShiftEnabled()
        states[.trueTone] = PrivateAPI.trueTone("available") == true ? PrivateAPI.trueTone("enabled") : nil
        states[.microphone] = (try? AudioMonitor(input: true).read().fields?["muted"]).map { $0 == "true" }
        bluetoothAccess = CBManager.authorization
        // Reading the power through IOBluetooth asks for access, so until it's allowed the bluetooth provider's shows.
        if bluetoothAccess == .allowedAlways, let power = PrivateAPI.bluetoothPowerState { states[.bluetooth] = power() == 1 }
        for tile in running { states[tile] = self.states[tile] }
        if states != self.states { self.states = states }
        let warmth = PrivateAPI.nightShiftStrength()
        if warmth != nightShiftStrength { nightShiftStrength = warmth }
        let local = NetworkDetails.localAddress()
        if local?.address != localAddress?.address || local?.interface != localAddress?.interface { localAddress = local }
        let network = Self.network(local)
        if network != self.network {
            self.network = network
            publicAddress = nil
            speedTest = nil
        }
    }

    /// What tells the network through `local` apart, so a result from another one is dropped: two networks can hand out
    /// the same address, so the router and the Wi-Fi network's name, which Location Services allows, count too.
    private static func network(_ local: (interface: String, address: String)?) -> [String?] {
        [local?.interface, local?.address, NetworkDetails.router(), local.flatMap { CWWiFiClient.shared().interface(withName: $0.interface)?.ssid() }]
    }

    /// Turns `tile` off when `on`, as it shows now, or on.
    @discardableResult
    func toggle(_ tile: QuickTile, from on: Bool) -> Task<Void, Never>? {
        guard acts, !running.contains(tile) else { return nil }
        states[tile] = !on
        return run(tile) { try await self.set(tile, !on) }
    }

    private func set(_ tile: QuickTile, _ on: Bool) async throws {
        switch tile {
        case .darkMode: try await Self.tell("System Events", "tell appearance preferences to set dark mode to \(on)")
        case .dockAutohide: try await Self.tell("System Events", "tell dock preferences to set autohide to \(on)")
        case .desktopIcons: try await Self.setFinderFlag("CreateDesktop", !on)
        case .hiddenFiles: try await Self.setFinderFlag("AppleShowAllFiles", on)
        case .nightShift:
            if !PrivateAPI.setNightShift(on) { throw CommandFailure(message: "macOS didn't change Night Shift.") }
        case .trueTone:
            if !PrivateAPI.setTrueTone(on) { throw CommandFailure(message: "macOS didn't change True Tone.") }
        case .bluetooth:
            // The first time, macOS asks whether StableBar may use Bluetooth.
            if let set = PrivateAPI.setBluetoothPowerState { try await BlockingWork.run { set(on ? 1 : 0) } }
        case .microphone: try AudioMonitor.setMuted(on, input: true)
        default: break
        }
    }

    func setMirrored(_ on: Bool) {
        attempt { try displays.setMirrored(on) }
    }

    func setMode(_ mode: DisplayModeOption, of display: CGDirectDisplayID) {
        attempt { try displays.setMode(mode, of: display) }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch let failure {
            error = errorMessage(failure)
        }
    }

    func setNightShiftStrength(_ level: Double) {
        guard acts else { return }
        if PrivateAPI.setNightShiftStrength(level) { nightShiftStrength = level } else { error = "macOS didn't change Night Shift’s warmth." }
    }

    /// Asks `NetworkDetails.publicAddressService` for the public address, only when the person asks.
    func showPublicAddress() {
        guard acts, !fetchesPublicAddress else { return }
        fetchesPublicAddress = true
        let started = Self.network(NetworkDetails.localAddress())
        Task {
            do {
                let address = try await NetworkDetails.publicAddress()
                if Self.network(NetworkDetails.localAddress()) == started { publicAddress = address }
            } catch let failure {
                error = errorMessage(failure)
            }
            fetchesPublicAddress = false
        }
    }

    func testSpeed() {
        guard acts, !testsSpeed else { return }
        testsSpeed = true
        let started = Self.network(NetworkDetails.localAddress())
        Task {
            do {
                let test = try await NetworkDetails.speedTest()
                if Self.network(NetworkDetails.localAddress()) == started { speedTest = test }
            } catch let failure {
                error = errorMessage(failure)
            }
            testsSpeed = false
        }
    }

    /// Runs a tool.
    func press(_ tile: QuickTile) {
        guard acts, !running.contains(tile) else { return }
        switch tile {
        case .lockScreen:
            error = lockScreen()
        case .sleepDisplay:
            run(tile) { _ = try await runCommand("/usr/bin/pmset", arguments: ["displaysleepnow"]) }
        case .screenSaver:
            OpenTarget("com.apple.ScreenSaver.Engine")!.open()
        case .screenshot:
            OpenTarget("com.apple.screenshot.launcher")!.open()
        case .colorPicker:
            NSColorSampler().show { [weak self] color in
                guard let color = color?.usingColorSpace(.sRGB) else { return }
                MainActor.assumeIsolated {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.hex(color), forType: .string)
                    self?.showPicked(color)
                }
            }
        case .cameraMirror:
            run(tile) { try await self.camera.toggle() }
        case .clearClipboard:
            NSPasteboard.general.clearContents()
            flash(tile)
        case .hideApps:
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { app.hide() }
        case .emptyTrash:
            run(tile) { try await Self.tell("Finder", "empty trash") }
        case .ejectDisks:
            let volumes = ejectable
            run(tile) { try await Self.ejectDrives(of: volumes, with: .live) }
        default:
            break
        }
    }

    /// Ejects the drives of `volumes`, each once since ejecting a drive ejects its other volumes too, and then says which
    /// it couldn't.
    static func ejectDrives(of volumes: [DiskVolume], with ejector: VolumeEjector) async throws {
        var drives = Set<String>()
        var failures: [String] = []
        for volume in volumes where volume.drive.map({ drives.insert($0).inserted }) ?? true {
            do {
                try await ejector.eject(volume.path, .drive)
            } catch {
                failures.append("\(volume.name): \(errorMessage(error))")
            }
        }
        if !failures.isEmpty { throw CommandFailure(message: failures.joined(separator: "\n")) }
    }

    private func showPicked(_ color: NSColor) {
        pickedColor = color
        Task {
            try? await Task.sleep(for: .seconds(4))
            if pickedColor == color { pickedColor = nil }
        }
    }

    private func flash(_ tile: QuickTile) {
        done = tile
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if done == tile { done = nil }
        }
    }

    private func readEjectable() {
        Task {
            ejectable = (try? await BlockingWork.run { try SystemVolumes().read() })?.others.filter(\.ejectable) ?? []
        }
    }

    /// Runs `work` for `tile`, shows why it failed, and reads again once it's done.
    @discardableResult
    private func run(_ tile: QuickTile, _ work: @escaping () async throws -> Void) -> Task<Void, Never> {
        running.insert(tile)
        return Task {
            do {
                try await work()
                error = nil
                if tile.group == .tools { flash(tile) }
            } catch let failure {
                error = errorMessage(failure)
            }
            running.remove(tile)
            read()
            if tile == .ejectDisks { readEjectable() }
        }
    }

    /// Shows the networks nearby at once, from the last scan or else CoreWLAN's, then scans again.
    func showNetworks() {
        guard acts else { return }
        if networks == nil, let interface = CWWiFiClient.shared().interface(), let cached = interface.cachedScanResults() {
            networks = WiFiNetwork.list(Self.networks(cached, on: interface), joined: interface.ssid())
        }
        scan()
    }

    /// Scans for the networks nearby, which CoreWLAN blocks for a few seconds, and updates the list in place.
    private func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            do {
                let (found, joined) = try await BlockingWork.run {
                    guard let interface = CWWiFiClient.shared().interface() else { throw CommandFailure(message: "This Mac has no Wi-Fi.") }
                    return (Self.networks(try interface.scanForNetworks(withName: nil), on: interface), interface.ssid())
                }
                networks = WiFiNetwork.merged(networks ?? [], with: found, joined: joined)
                error = nil
            } catch let failure {
                error = errorMessage(failure)
            }
            scanning = false
        }
    }

    /// The networks in `found` that have a name, which CoreWLAN gives only with Location access, saved or not.
    private nonisolated static func networks(_ found: Set<CWNetwork>, on interface: CWInterface) -> [WiFiNetwork] {
        let known = Set((interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid))
        return found.compactMap { network in
            guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
            return WiFiNetwork(ssid: ssid, rssi: network.rssiValue, secure: !network.supportsSecurity(.none), known: known.contains(ssid))
        }
    }

    func choose(_ network: WiFiNetwork) { perform(join.handle(.choose(network))) }
    func submit(password: String) { perform(join.handle(.submit(password: password))) }
    func cancelJoin() { _ = join.handle(.cancel) }

    private func perform(_ effects: [WiFiJoin.Effect]) {
        guard acts else { return }
        for case let .join(ssid, password) in effects {
            Task {
                do {
                    try await BlockingWork.run {
                        guard let interface = CWWiFiClient.shared().interface(),
                              let network = try interface.scanForNetworks(withName: ssid).max(by: { $0.rssiValue < $1.rssiValue }) else {
                            throw CommandFailure(message: "\(ssid) is out of range.")
                        }
                        try interface.associate(to: network, password: password)
                    }
                    _ = join.handle(.joined)
                    scan()
                } catch let failure {
                    _ = join.handle(.failure(failure))
                }
            }
        }
    }

    /// An sRGB color as `#RRGGBB`.
    static func hex(_ color: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
               Int((color.blueComponent * 255).rounded()))
    }

    /// Another app's preference, read again rather than from the cache: Finder, the Dock and System Settings write them.
    private static func preference(_ key: String, in domain: String) -> String? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
    }

    /// Another app's preference as a flag, however it was written, such as `YES` by `defaults write`; nil when unset.
    private static func flag(_ key: String, in domain: String) -> Bool? {
        CFPreferencesAppSynchronize(domain as CFString)
        var valid: DarwinBoolean = false
        let value = CFPreferencesGetAppBooleanValue(key as CFString, domain as CFString, &valid)
        return valid.boolValue ? value : nil
    }

    /// Sends `command` to `app` through AppleScript, which macOS asks the person to allow once per app.
    private static func tell(_ app: String, _ command: String) async throws {
        _ = try await runCommand("/usr/bin/osascript", arguments: ["-e", "tell application \"\(app)\" to \(command)"], timeout: 120)
    }

    /// Finder reads its preferences only as it starts, so this restarts it while it runs: macOS opens it again after it
    /// quits this way.
    private static func setFinderFlag(_ key: String, _ value: Bool) async throws {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, "com.apple.finder" as CFString)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty else { return }
        _ = try await runCommand("/usr/bin/killall", arguments: ["Finder"])
    }
}
