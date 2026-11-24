import Foundation

/// The Quick toggles' Keep awake: whether StableBar keeps the Mac from sleeping, until when, and whether it holds its
/// power assertion now. With `onPowerOnly`, it lets the Mac sleep on battery until power is back. Its owner,
/// `KeepAwake`, holds the assertion, runs the timer and follows the power source and the app it waits for.
struct KeepAwakeState: StateMachine, Equatable {
    /// The person's choices, kept across launches.
    struct Options: Codable, Equatable, Sendable {
        /// Whether the display may sleep while the Mac stays awake.
        var displaySleeps = false
        var onPowerOnly = false
    }

    struct App: Equatable, Sendable {
        let pid: pid_t
        let name: String
    }

    /// When it stops keeping the Mac awake.
    enum Until: Equatable, Sendable {
        case minutes(Int)
        case turnedOff
        case appQuits(App)
    }

    enum Mode: Equatable, Sendable {
        case off
        /// On as `Until` says, until `end` for minutes.
        case on(Until, end: Date?)
    }

    /// The assertion it holds: the Mac's, or the display's too, which keeps the Mac awake as well.
    enum Hold: Equatable, Sendable {
        case system, display
    }

    enum Event: Equatable {
        case turnOn(Until, now: Date)
        case turnOff
        /// The timer reached the end.
        case ended
        case appQuit(pid_t)
        /// macOS refused the assertion, so it turns off and turning it on again tries again.
        case holdFailed
        case powerChanged(onPower: Bool)
        case setOptions(Options)
    }

    enum Effect: Equatable {
        /// Holds `Hold`'s assertion in place of the one held.
        case hold(Hold)
        case release
        /// Runs the timer to that date, or with nil, stops it.
        case endAt(Date?)
        case save(Options)
    }

    private(set) var mode = Mode.off
    private(set) var options: Options
    private(set) var onPower = true
    private(set) var holding: Hold?

    init(options: Options = Options()) {
        self.options = options
    }

    /// The minutes left at `date`, rounded up, while it's on for a number of minutes.
    func minutesLeft(at date: Date) -> Int? {
        guard case let .on(_, end?) = mode else { return nil }
        return max(Int((end.timeIntervalSince(date) / 60).rounded(.up)), 1)
    }

    mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        switch event {
        case let .turnOn(until, now):
            let end: Date? = if case let .minutes(minutes) = until { now.addingTimeInterval(Double(minutes) * 60) } else { nil }
            mode = .on(until, end: end)
            effects.append(.endAt(end))
        case .turnOff, .ended, .holdFailed:
            guard mode != .off else { return [] }
            mode = .off
            effects.append(.endAt(nil))
        case let .appQuit(pid):
            guard case let .on(.appQuits(app), _) = mode, app.pid == pid else { return [] }
            mode = .off
        case let .powerChanged(onPower):
            self.onPower = onPower
        case let .setOptions(options):
            self.options = options
            effects.append(.save(options))
        }
        let wanted: Hold? = mode == .off || options.onPowerOnly && !onPower ? nil : options.displaySleeps ? .system : .display
        if wanted != holding {
            effects.append(wanted.map(Effect.hold) ?? .release)
            holding = wanted
        }
        return effects
    }
}
