import CoreGraphics
import Foundation
@testable import StableBar
import Testing

/// A 40-point bar over a 1024x768 display whose Dock leaves 712 points: a window filled from its title bar
/// covers `filled`, and keeping it clear means `clear`.
private let filled = CGRect(x: 0, y: 0, width: 1024, height: 712)
private let clear = CGRect(x: 0, y: 40, width: 1024, height: 672)
private let shrunk = CGRect(x: 0, y: 0, width: 1024, height: 672)
private let start = Date(timeIntervalSinceReferenceDate: 0)

private func seen(_ frame: CGRect, _ target: CGRect?, at time: Date, canMove: Bool = true,
                  canResize: Bool = true) -> WindowAdjustment.Event {
    .seen(frame: frame, target: target, canMove: canMove, canResize: canResize, at: time)
}

@Test func aWindowUnderTheBarIsShrunkThenMovedBelowIt() {
    var adjustment = WindowAdjustment()
    #expect(adjustment.handle(seen(filled, clear, at: start)) == [.resize(clear.size)])
    #expect(adjustment.handle(seen(shrunk, clear, at: start)) == [.move(clear.origin)])
    #expect(adjustment.handle(seen(clear, nil, at: start)) == [])
}

@Test func aWindowThatFitsBelowTheBarIsOnlyMoved() {
    var adjustment = WindowAdjustment()
    let window = CGRect(x: 100, y: 20, width: 600, height: 400)
    let target = CGRect(x: 100, y: 40, width: 600, height: 400)
    #expect(adjustment.handle(seen(window, target, at: start)) == [.move(target.origin)])
}

@Test func aChangeMacOSUndoesIsTriedAgainOnceTheWindowSettles() {
    var adjustment = WindowAdjustment()
    _ = adjustment.handle(seen(filled, clear, at: start))
    // macOS puts a window it has just filled back to the filled frame.
    let undone = start.addingTimeInterval(0.15)
    let retry = undone.addingTimeInterval(WindowAdjustment.retryDelays[0])
    #expect(adjustment.handle(seen(filled, clear, at: undone)) == [.checkAgain(at: retry)])
    // Another app's notification brings an earlier pass: still too soon.
    #expect(adjustment.handle(seen(filled, clear, at: undone.addingTimeInterval(0.2))) == [.checkAgain(at: retry)])
    #expect(adjustment.handle(seen(filled, clear, at: retry)) == [.resize(clear.size)])
    #expect(adjustment.handle(seen(shrunk, clear, at: retry)) == [.move(clear.origin)])
    #expect(adjustment.handle(seen(clear, nil, at: retry)) == [])
}

@Test func aWindowThatKeepsRefusingIsLeftAloneAfterTheLastTry() {
    var adjustment = WindowAdjustment()
    var now = start
    _ = adjustment.handle(seen(filled, clear, at: now))
    for delay in WindowAdjustment.retryDelays {
        now = now.addingTimeInterval(0.15)
        #expect(adjustment.handle(seen(filled, clear, at: now)) == [.checkAgain(at: now.addingTimeInterval(delay))])
        now = now.addingTimeInterval(delay)
        #expect(adjustment.handle(seen(filled, clear, at: now)) == [.resize(clear.size)])
    }
    #expect(adjustment.handle(seen(filled, clear, at: now.addingTimeInterval(0.15))) == [])
    #expect(adjustment.handle(seen(filled, clear, at: now.addingTimeInterval(60))) == [])
}

@Test func aWindowMovedBackUnderTheBarAfterItWasClearIsAdjustedAgain() {
    var adjustment = WindowAdjustment()
    let window = CGRect(x: 100, y: 20, width: 600, height: 400)
    let target = CGRect(x: 100, y: 40, width: 600, height: 400)
    #expect(adjustment.handle(seen(window, target, at: start)) == [.move(target.origin)])
    #expect(adjustment.handle(seen(target, nil, at: start)) == [])
    #expect(adjustment.handle(seen(window, target, at: start)) == [.move(target.origin)])
}

@Test func aWindowMovedElsewhereWhileWaitingIsAdjustedAtOnce() {
    var adjustment = WindowAdjustment()
    _ = adjustment.handle(seen(filled, clear, at: start))
    _ = adjustment.handle(seen(filled, clear, at: start.addingTimeInterval(0.15)))
    let dragged = CGRect(x: 200, y: 10, width: 500, height: 300)
    let target = CGRect(x: 200, y: 40, width: 500, height: 300)
    #expect(adjustment.handle(seen(dragged, target, at: start.addingTimeInterval(0.3))) == [.move(target.origin)])
}

@Test func aWindowMovedElsewhereAfterTheLastTryIsAdjustedAtOnce() {
    var adjustment = WindowAdjustment()
    var now = start
    _ = adjustment.handle(seen(filled, clear, at: now))
    for delay in WindowAdjustment.retryDelays {
        now = now.addingTimeInterval(0.15)
        _ = adjustment.handle(seen(filled, clear, at: now))
        now = now.addingTimeInterval(delay)
        _ = adjustment.handle(seen(filled, clear, at: now))
    }
    #expect(adjustment.handle(seen(filled, clear, at: now.addingTimeInterval(0.15))) == [])
    let dragged = CGRect(x: 200, y: 10, width: 500, height: 300)
    let target = CGRect(x: 200, y: 40, width: 500, height: 300)
    #expect(adjustment.handle(seen(dragged, target, at: now.addingTimeInterval(1))) == [.move(target.origin)])
}

@Test func triesStartAgainOnceTheWindowIsClear() {
    var adjustment = WindowAdjustment()
    var now = start
    _ = adjustment.handle(seen(filled, clear, at: now))
    for delay in WindowAdjustment.retryDelays {
        now = now.addingTimeInterval(0.15)
        _ = adjustment.handle(seen(filled, clear, at: now))
        now = now.addingTimeInterval(delay)
        _ = adjustment.handle(seen(filled, clear, at: now))
    }
    #expect(adjustment.handle(seen(clear, nil, at: now)) == [])
    #expect(adjustment.handle(seen(filled, clear, at: now)) == [.resize(clear.size)])
    let undone = now.addingTimeInterval(0.15)
    #expect(adjustment.handle(seen(filled, clear, at: undone))
            == [.checkAgain(at: undone.addingTimeInterval(WindowAdjustment.retryDelays[0]))])
}

@Test func aWindowThatCantMoveYetKeepsItsTriesUntilItCan() {
    var adjustment = WindowAdjustment()
    var now = start
    for _ in 0...WindowAdjustment.retryDelays.count + 1 {
        #expect(adjustment.handle(seen(filled, clear, at: now, canMove: false)) == [])
        now = now.addingTimeInterval(1)
    }
    #expect(adjustment.handle(seen(filled, clear, at: now)) == [.resize(clear.size)])
}

@Test func aWindowThatNeedsShrinkingIsLeftUntilItCanBeResized() {
    var adjustment = WindowAdjustment()
    #expect(adjustment.handle(seen(filled, clear, at: start, canResize: false)) == [])
    #expect(adjustment.handle(seen(filled, clear, at: start.addingTimeInterval(1))) == [.resize(clear.size)])
}

@Test func aWindowThatCantBeResizedIsStillMovedWhenItFits() {
    var adjustment = WindowAdjustment()
    let window = CGRect(x: 100, y: 20, width: 600, height: 400)
    let target = CGRect(x: 100, y: 40, width: 600, height: 400)
    #expect(adjustment.handle(seen(window, target, at: start, canResize: false)) == [.move(target.origin)])
}

@Test func aWindowThatCantMoveIsShrunkWhenThatAloneClearsTheBar() {
    // A bar at the bottom: shrinking a filled window keeps its top and lifts its bottom clear of the bar.
    var adjustment = WindowAdjustment()
    let aboveBar = CGRect(x: 0, y: 0, width: 1024, height: 672)
    #expect(adjustment.handle(seen(filled, aboveBar, at: start, canMove: false)) == [.resize(aboveBar.size)])
}
