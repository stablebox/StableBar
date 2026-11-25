import SwiftUI

/// The colors of glass in `colorScheme`: white glass and text over a dark image, and dark text on more opaque glass over
/// a light one.
struct GlassPalette {
    let dark: Bool

    init(_ colorScheme: ColorScheme) {
        dark = colorScheme == .dark
    }

    /// Text and symbols, and the fill of a selected control.
    var ink: Color { dark ? .white : Color(red: 0.09, green: 0.08, blue: 0.16) }
    /// Text on a selected control.
    var inkOnSelected: Color { dark ? .black : .white }
    var edge: Color { ink.opacity(dark ? 0.24 : 0.14) }
    /// Under a card or a toolbar, setting it apart from the image behind.
    var backing: Color { dark ? .black.opacity(0.3) : .white.opacity(0.3) }

    /// White glass `opacity` strong over a dark image. Over a light one, glass that faint wouldn't show.
    func fill(_ opacity: Double) -> Color {
        .white.opacity(dark ? opacity : min(opacity * 3.5, 0.9))
    }
}

/// The controls Share My Bar and setup draw over an image or a wallpaper.
extension View {
    /// A translucent fill and edge. Their capsules are circular: a continuous capsule's edge gets a stray straight line
    /// beside it in offscreen drawings.
    func glass(_ shape: some InsettableShape) -> some View {
        modifier(GlassSurface(shape: shape))
    }

    /// The pointing hand over a control. SwiftUI drops it with the control, which a pushed NSCursor doesn't survive.
    @ViewBuilder func linkPointer() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
}

private struct GlassSurface<Shape: InsettableShape>: ViewModifier {
    let shape: Shape
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = GlassPalette(colorScheme)
        return content
            .background(palette.fill(0.15), in: shape)
            .overlay(shape.pixelBorder(palette.edge, width: 0.5))
    }
}

/// A capsule button on glass: a segment, a tool, or the primary action, which is `selected` like the chosen segment.
struct GlassButtonStyle: ButtonStyle {
    enum Size { case compact, regular, large }

    var selected: Bool
    var highlighted = false
    var round = false
    var size = Size.regular
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var palette: GlassPalette { GlassPalette(colorScheme) }

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let (font, padding, height): (Double, Double, Double) = switch size {
        case .compact: (11.5, 10, 26)
        case .regular: (12, 12, 36)
        case .large: (15, 22, 48)
        }
        return configuration.label
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(selected ? palette.inkOnSelected : palette.ink)
            .padding(.horizontal, round ? 0 : padding)
            .frame(minWidth: size == .compact ? 0 : height, minHeight: height)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .linkPointer()
    }

    private func fill(pressed: Bool) -> Color {
        if selected { return palette.ink.opacity(pressed ? 0.75 : 0.92) }
        return palette.fill(pressed ? 0.28 : highlighted ? 0.22 : 0)
    }
}

/// The round × in a corner, which Esc presses too.
struct GlassCloseButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .glass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .linkPointer()
        .keyboardShortcut(.cancelAction)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A pill that opens a menu: its title and a chevron.
struct GlassPill<Title: View>: View {
    @ViewBuilder let title: Title

    var body: some View {
        HStack(spacing: 6) {
            title
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .glass(Capsule(style: .circular))
        .contentShape(Capsule())
    }
}
