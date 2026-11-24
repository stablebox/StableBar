import AppKit

/// The Quick toggles' displays: each one's brightness, from its own, through DisplayServices for the built-in display
/// and DDC/CI for the others, down into software dimming below it, its resolution, and mirroring. Software dimming
/// lasts until StableBar quits, and a relaunch starts undimmed.
@MainActor @Observable
final class DisplayControls {
    struct Display: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let builtIn: Bool
        /// The brightness slider, from 0 to 1, as `BrightnessScale` splits it.
        var level: Double
        /// Whether the slider sets the display's own brightness above software dimming.
        var ownBrightness: Bool
        /// The resolutions to choose from, and the one in use.
        var modes: [DisplayModeOption]
        var mode: DisplayModeOption?
    }

    private(set) var displays: [Display] = []
    private(set) var mirrored = false
    @ObservationIgnored private let dimmer = DisplayDimmer()
    @ObservationIgnored private var ddc: [CGDirectDisplayID: DDC] = [:]
    /// Each external display's own maximum brightness, as it reported it.
    @ObservationIgnored private var maxima: [CGDirectDisplayID: UInt16] = [:]
    @ObservationIgnored private var writes: [CGDirectDisplayID: LatestWrite<UInt16>] = [:]
    /// How many times each display's slider moved, so a brightness read from before the last move doesn't move it back.
    @ObservationIgnored private var moves: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var acts = true
    /// The display whose resolutions a scene draws open.
    @ObservationIgnored private(set) var opensExpanded: CGDirectDisplayID?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dimmer.displaysChanged() }
        }
    }

    /// Displays showing these, which never read or change the Mac, for drawing scenes.
    init(sample displays: [Display], mirrored: Bool, expanded: CGDirectDisplayID?) {
        self.displays = displays
        self.mirrored = mirrored
        opensExpanded = expanded
        acts = false
    }

    /// Reads the displays as the panel opens and as they change while it's open, and asks each external one for its
    /// brightness, which takes a moment.
    func read() {
        guard acts else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let online = Array(ids.prefix(Int(count)))
        mirrored = online.contains { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
        displays = online.map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let known = displays.first { $0.id == id }
            let own = builtIn ? Self.builtInBrightness(id) : nil
            let level = builtIn ? BrightnessScale.level(brightness: own, dim: dimmer.dim(of: id))
                : known?.level ?? BrightnessScale.level(brightness: nil, dim: dimmer.dim(of: id))
            let current = CGDisplayCopyDisplayMode(id).map(Self.option)
            let all = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? [])
                .map(Self.option)
            return Display(id: id, name: DisplayDimmer.screen(of: id)?.localizedName ?? (builtIn ? "Built-in Display" : "Display"),
                           builtIn: builtIn, level: level, ownBrightness: builtIn ? own != nil : known?.ownBrightness ?? false,
                           modes: current.map { DisplayModeOption.choices(all, current: $0) } ?? [], mode: current)
        }
        let external = online.filter { CGDisplayIsBuiltin($0) == 0 }
        guard !external.isEmpty else { return }
        let started = moves
        Task {
            let found = await (try? BlockingWork.run { DDC.services(for: external) }) ?? [:]
            ddc = found
            for (id, service) in found {
                guard let reply = try? await BlockingWork.run({ try service.read(DDC.brightness) }) else { continue }
                maxima[id] = reply.maximum
                let moved = moves[id] != started[id]
                // A write under way can still answer with the brightness from before it.
                let current = !moved && writes[id, default: LatestWrite()].mode == .idle
                update(id) { display in
                    display.ownBrightness = true
                    if current {
                        display.level = BrightnessScale.level(brightness: Double(min(reply.value, reply.maximum)) / Double(reply.maximum),
                                                              dim: dimmer.dim(of: id))
                    }
                }
                // A move before the display answered only dimmed it in software, so its own brightness takes the level over.
                if moved, let level = displays.first(where: { $0.id == id })?.level { setLevel(level, of: id) }
            }
        }
    }

    /// Reads the built-in display's brightness again, which its keys change.
    func readBuiltIn() {
        guard acts else { return }
        for display in displays where display.builtIn {
            guard let own = Self.builtInBrightness(display.id) else { continue }
            let level = BrightnessScale.level(brightness: own, dim: dimmer.dim(of: display.id))
            if abs(level - display.level) > 0.001 { update(display.id) { $0.level = level } }
        }
    }

    func setLevel(_ level: Double, of id: CGDirectDisplayID) {
        guard acts, let display = displays.first(where: { $0.id == id }) else { return }
        moves[id, default: 0] += 1
        update(id) { $0.level = level }
        let (own, dim) = BrightnessScale.split(level, ownBrightness: display.ownBrightness)
        dimmer.dim(id, by: dim)
        guard let own else { return }
        if display.builtIn {
            _ = PrivateAPI.setBrightness?(id, Float(own))
        } else if let maximum = maxima[id] {
            perform(writes[id, default: LatestWrite()].handle(.set(UInt16((own * Double(maximum)).rounded()))), on: id)
        }
    }

    /// Sends the latest brightness only: DDC/CI takes about 70 ms a command, slower than a slider moves.
    private func perform(_ effects: [LatestWrite<UInt16>.Effect], on id: CGDirectDisplayID) {
        for case let .write(value) in effects {
            // A display whose service went away starts its writes over once it's found again.
            guard let service = ddc[id] else {
                writes[id] = nil
                return
            }
            Task {
                try? await BlockingWork.run { try service.write(DDC.brightness, value) }
                perform(writes[id, default: LatestWrite()].handle(.finished), on: id)
            }
        }
    }

    func setMode(_ mode: DisplayModeOption, of id: CGDirectDisplayID) throws {
        guard acts else { return }
        let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
        guard let chosen = modes.first(where: { $0.ioDisplayModeID == mode.id }) else { return }
        try configure { CGConfigureDisplayWithDisplayMode($0, id, chosen, nil) }
        read()
    }

    /// Mirrors every display of the main one, or shows each its own desktop again.
    func setMirrored(_ on: Bool) throws {
        guard acts else { return }
        let main = CGMainDisplayID()
        try configure { config in
            for display in displays where display.id != main {
                let result = CGConfigureDisplayMirrorOfDisplay(config, display.id, on ? main : kCGNullDirectDisplay)
                if result != .success { return result }
            }
            return .success
        }
        read()
    }

    /// Changes the displays as System Settings does, for good.
    private func configure(_ change: (CGDisplayConfigRef?) -> CGError) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { throw CommandFailure(message: "macOS didn't change the displays.") }
        guard change(config) == .success, CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            throw CommandFailure(message: "macOS didn't change the displays.")
        }
    }

    func restore() {
        dimmer.restore()
    }

    private func update(_ id: CGDirectDisplayID, _ change: (inout Display) -> Void) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        change(&displays[index])
    }

    private static func builtInBrightness(_ id: CGDirectDisplayID) -> Double? {
        var level: Float = 0
        return PrivateAPI.getBrightness?(id, &level) == 0 ? Double(level) : nil
    }

    private static func option(_ mode: CGDisplayMode) -> DisplayModeOption {
        DisplayModeOption(id: mode.ioDisplayModeID, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                          pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate, usable: mode.isUsableForDesktopGUI(),
                          isDefault: mode.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0)
    }
}
