import Foundation

/// One slider for a display's brightness: its top part sets the display's own brightness, and its bottom part dims it
/// further in software, below the darkest the display goes. Without control of the display's own brightness, the whole
/// slider dims in software.
enum BrightnessScale {
    /// The share of the slider below the display's own minimum.
    static let dimmedShare = 0.2
    /// The software dimming at the bottom of the slider, short of black so the screen stays readable.
    static let deepest = 0.85

    /// The display's own brightness `level` sets, nil without control of it, and the software dimming over it, both
    /// from 0 to 1.
    static func split(_ level: Double, ownBrightness: Bool) -> (brightness: Double?, dim: Double) {
        guard ownBrightness else { return (nil, (1 - level) * deepest) }
        if level >= dimmedShare { return ((level - dimmedShare) / (1 - dimmedShare), 0) }
        return (0, (dimmedShare - level) / dimmedShare * deepest)
    }

    /// The slider's level for the display's own brightness, nil without control of it, and the software dimming.
    static func level(brightness: Double?, dim: Double) -> Double {
        guard let brightness else { return 1 - dim / deepest }
        return dim > 0 ? dimmedShare * (1 - dim / deepest) : dimmedShare + brightness * (1 - dimmedShare)
    }
}

/// A display mode, as the Display card offers it.
struct DisplayModeOption: Equatable, Sendable, Identifiable {
    /// The mode's `ioDisplayModeID`.
    let id: Int32
    /// In points.
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let usable: Bool
    /// The mode macOS picks for the display.
    let isDefault: Bool

    var hiDPI: Bool { pixelWidth > width }

    /// The modes to choose from, as System Settings offers them, from larger text to more space: one for each size in
    /// points, sharp where the display can draw it at twice its pixels, at the refresh rate and in the shape of the
    /// display, and the mode in use whatever it is.
    static func choices(_ modes: [DisplayModeOption], current: DisplayModeOption) -> [DisplayModeOption] {
        guard let native = modes.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else { return [current] }
        let shape = Double(native.pixelWidth) / Double(native.pixelHeight)
        let fitting = modes.filter { mode in
            mode.usable && mode.refreshRate == current.refreshRate && abs(Double(mode.width) / Double(mode.height) / shape - 1) < 0.02
        }
        let chosen = Dictionary(grouping: fitting) { [$0.width, $0.height] }.values.map { sameSize in
            sameSize.first { $0 == current } ?? sameSize.first(where: \.hiDPI) ?? sameSize[0]
        }
        return (chosen.contains(current) ? chosen : chosen + [current]).sorted { $0.width < $1.width }
    }
}
