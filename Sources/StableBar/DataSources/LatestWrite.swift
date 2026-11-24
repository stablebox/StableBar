/// Writes that take a while, such as a display's brightness over DDC, from a control that moves faster than they finish:
/// while one is under way only the newest value waits, and it's written once that one finishes. Its owner writes and
/// says when each write ends.
struct LatestWrite<Value: Equatable>: StateMachine, Equatable {
    enum Mode: Equatable {
        case idle
        /// A write is under way, and `waiting` is written after it.
        case writing(waiting: Value?)
    }

    enum Event: Equatable {
        case set(Value)
        case finished
    }

    enum Effect: Equatable {
        case write(Value)
    }

    private(set) var mode = Mode.idle

    mutating func handle(_ event: Event) -> [Effect] {
        switch (event, mode) {
        case let (.set(value), .idle):
            mode = .writing(waiting: nil)
            return [.write(value)]
        case let (.set(value), .writing):
            mode = .writing(waiting: value)
            return []
        case let (.finished, .writing(waiting?)):
            mode = .writing(waiting: nil)
            return [.write(waiting)]
        case (.finished, _):
            mode = .idle
            return []
        }
    }
}
