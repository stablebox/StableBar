/// Why scripts and providers are paused: they run again once none of these holds.
enum PauseReason: CaseIterable {
    case systemAsleep, displaysAsleep, screenLocked, sessionInactive
}
