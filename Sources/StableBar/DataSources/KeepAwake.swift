import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac awake for the Quick toggles, with a power assertion like `caffeinate`'s, as `KeepAwakeState` decides.
/// While it's on, it follows the power source and the app it waits for.
@MainActor @Observable
final class KeepAwake {
    /// The person's options, kept across launches.
    static let optionsKey = "keepAwake"

    private(set) var state: KeepAwakeState
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let power = PowerMonitor()
    @ObservationIgnored private var appObserver: NSObjectProtocol?
    /// Whether it holds assertions, which a scene's sample doesn't.
    @ObservationIgnored private var acts = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.optionsKey).flatMap { try? JSONDecoder().decode(KeepAwakeState.Options.self, from: $0) }
        state = KeepAwakeState(options: saved ?? KeepAwakeState.Options())
    }

    /// Keep awake showing `state`, which never holds an assertion, for drawing scenes.
    init(sample state: KeepAwakeState) {
        defaults = .standard
        self.state = state
        acts = false
    }

    func turnOn(_ until: KeepAwakeState.Until) {
        handle(.turnOn(until, now: .now))
        // The app can quit while the person chooses it, before the observer that waits for it.
        if case let .appQuits(app) = until, NSRunningApplication(processIdentifier: app.pid)?.isTerminated != false { handle(.appQuit(app.pid)) }
    }
    func turnOff() { handle(.turnOff) }
    func setOptions(_ options: KeepAwakeState.Options) { handle(.setOptions(options)) }

    private func handle(_ event: KeepAwakeState.Event) {
        guard acts else { return }
        for effect in state.handle(event) { perform(effect) }
        follow(state.mode != .off)
    }

    private func perform(_ effect: KeepAwakeState.Effect) {
        switch effect {
        case let .hold(hold):
            release()
            let type = hold == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "StableBar’s Keep Awake" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            } else {
                handle(.holdFailed)
            }
        case .release:
            release()
        case let .endAt(end):
            timer?.cancel()
            timer = end.map { end in
                Task { [weak self] in
                    // The continuous clock counts while the Mac sleeps, so the timer still ends on time after the lid closes.
                    try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow), clock: .continuous)
                    if !Task.isCancelled { self?.handle(.ended) }
                }
            }
        case let .save(options):
            defaults.set(try? JSONEncoder().encode(options), forKey: Self.optionsKey)
        }
    }

    private func release() {
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
    }

    /// Follows the power source and the apps that quit while it's on.
    private func follow(_ on: Bool) {
        guard on != (appObserver != nil) else { return }
        if on {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                            object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.handle(.appQuit(app.processIdentifier)) }
            }
            try? power.start { [weak self] in MainActor.assumeIsolated { self?.readPower() } }
            readPower()
        } else {
            power.stop()
            if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
            appObserver = nil
        }
    }

    /// What the Quick toggles widget shows on the bar at `date` while this is on: a cup, with the time left.
    func barOutput(at date: Date) -> ScriptOutput? {
        guard state.mode != .off else { return nil }
        let left = state.minutesLeft(at: date).map { $0 >= 60 ? "\($0 / 60)h \($0 % 60)m" : "\($0)m" }
        return ScriptOutput(text: left ?? "", fields: ["keepAwake": "on"])
    }

    private func readPower() {
        guard let source = (try? power.read())?.fields?["state"] else { return }
        let onPower = source != "battery"
        if onPower != state.onPower { handle(.powerChanged(onPower: onPower)) }
    }
}
