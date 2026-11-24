import AppKit

/// Dims displays below the darkest they go, with a black window over each that clicks go through and screenshots and
/// recordings leave out. A window rather than the display's gamma table, which Night Shift and True Tone also set: the
/// window darkens the screen under their colors instead of fighting them. Its windows go with StableBar, so a display
/// is never left dimmed.
@MainActor
final class DisplayDimmer {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    /// How much `display` is dimmed, from 0 to 1.
    func dim(of display: CGDirectDisplayID) -> Double {
        windows[display].map { Double($0.alphaValue) } ?? 0
    }

    func dim(_ display: CGDirectDisplayID, by amount: Double) {
        guard amount > 0, let screen = Self.screen(of: display) else {
            windows.removeValue(forKey: display)?.close()
            return
        }
        let window = windows[display] ?? {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            // Over apps' windows and under StableBar's bar and popups, at the floating level, so the slider that dims
            // stays readable. The Dock and the macOS menu bar, higher still, keep the display's own brightness.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.sharingType = .none
            windows[display] = window
            return window
        }()
        window.setFrame(screen.frame, display: false)
        window.alphaValue = amount
        window.orderFrontRegardless()
    }

    /// Follows a display that moved or changed resolution, and lets go of one that's gone.
    func displaysChanged() {
        for (display, window) in windows {
            if let screen = Self.screen(of: display) { window.setFrame(screen.frame, display: false) } else { dim(display, by: 0) }
        }
    }

    func restore() {
        for display in windows.keys { dim(display, by: 0) }
    }

    static func screen(of display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
    }
}
