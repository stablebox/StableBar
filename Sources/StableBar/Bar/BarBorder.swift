import SwiftUI

/// Observe decoration separately from the bar's width measurement and horizontal planning.
struct BarSurface: ViewModifier {
    let store: BarStore
    let settings: BarSettings
    let kind: ScreenKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let style = store.barPresentation.barStyle(on: kind)
        let fill = style.background ?? settings.background
        content
            .modifier(FollowsBackground(fill: settings.glass.painted(fill, on: \.bar, reduceTransparency: reduceTransparency)))
            .clipShape(RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0)))
            .modifier(GlassBackground(fill: fill, glass: settings.glass, surface: \.bar,
                                      shape: RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))))
            .background {
                // A see-through strip shows the popups' surface, which the theme pairs with its text.
                if reduceTransparency {
                    let look = store.configuration!.look(on: kind)
                    Color.clear.modifier(GlassBackground(fill: look.popupDefaults.popupStyle(over: look.defaults).background, glass: settings.glass,
                                                         surface: \.popups, shape: RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))))
                }
            }
            .overlay { BarBorder(style: style) }
            .animation(reduceMotion ? nil : settings.animation.value, value: style)
    }
}

struct GlassBackground<S: Shape>: ViewModifier {
    let fill: BackgroundFill?
    let glass: GlassSettings
    let surface: KeyPath<GlassSettings, Bool>
    let shape: S
    /// Cast by the background alone, for a style whose `shadowFrom` is `shape`.
    var shadow: WidgetAppearance? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.glassBackdrop) private var backdrop

    func body(content: Content) -> some View {
        let painted = glass.painted(fill, on: surface, reduceTransparency: reduceTransparency)
        if #available(macOS 26, *), glass.enabled, glass[keyPath: surface], !reduceTransparency {
            // Keep one view structure while the color comes and goes (hover, open, data states): switching
            // branches rebuilds the content, which dismantles a widget's popup anchor and closes its popup.
            let visible = fill.map { (colorScheme == .dark ? $0.firstColor.dark : $0.firstColor.light) & 0xff > 0 } ?? false
            content.background {
                ZStack {
                    Color.clear.glassEffect(visible && backdrop == nil ? .clear : .identity, in: shape)
                    if let backdrop {
                        // Offscreen, nothing blurs what's behind the glass or lightens it. Glass on widgets and
                        // popups sits on the bar, so only the bar's shows the wallpaper.
                        ZStack {
                            if surface == \GlassSettings.bar { backdrop.view }
                            Color.white.opacity(0.14)
                        }
                        .clipShape(shape)
                        .opacity(visible ? 1 : 0)
                    }
                    shape.fill(painted?.shapeStyle ?? AnyShapeStyle(Color.clear))
                    if backdrop != nil {
                        // The light along the glass's edge, half of the stroke inside the shape.
                        shape.stroke(.white.opacity(visible ? 0.18 : 0), lineWidth: 2).clipShape(shape)
                    }
                }
                .styledShadow(shadow)
            }
        } else {
            let empty = if surface != \GlassSettings.popups {
                AnyShapeStyle(Color.clear)
            } else if reduceTransparency {
                AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            } else {
                AnyShapeStyle(.regularMaterial)
            }
            content.background { shape.fill(painted?.shapeStyle ?? empty).styledShadow(shadow) }
        }
    }
}

/// The wallpaper blurred as Liquid Glass blurs it on screen, for glass in an offscreen drawing, where the window server
/// doesn't draw it. `image` fills `size` points from the origin of the coordinate space named `space`, as the wallpaper.
struct GlassBackdrop {
    static let space = "glassBackdrop"
    let image: NSImage
    let size: CGSize

    /// The part of `image` behind the view.
    var view: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .named(Self.space)).origin
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size.width, height: size.height)
                .offset(x: -origin.x, y: -origin.y)
        }
    }
}

extension EnvironmentValues {
    @Entry var glassBackdrop: GlassBackdrop?
}

extension GlassSettings {
    /// `fill` as `GlassBackground` paints it on `surface`: faded by the transparency on Liquid Glass, and opaque under
    /// Reduce Transparency except on widgets, which keep their tints since they sit on the opaque bar or a popup.
    func painted(_ fill: BackgroundFill?, on surface: KeyPath<GlassSettings, Bool>, reduceTransparency: Bool) -> BackgroundFill? {
        if #available(macOS 26, *), enabled, self[keyPath: surface], !reduceTransparency { return fill?.faded(1 - transparency) }
        return reduceTransparency && surface != \GlassSettings.widgets ? fill?.opaque : fill
    }
}

private extension BackgroundFill {
    var opaque: BackgroundFill {
        switch self {
        case let .color(color): .color(color.opaque)
        case let .gradient(gradient):
            .gradient(BackgroundGradient(colors: gradient.colors.map(\.opaque), angle: gradient.angle, locations: gradient.locations))
        }
    }

    func faded(_ opacity: Double) -> BackgroundFill {
        switch self {
        case let .color(color): .color(color.faded(opacity))
        case let .gradient(gradient):
            .gradient(BackgroundGradient(colors: gradient.colors.map { $0.faded(opacity) }, angle: gradient.angle, locations: gradient.locations))
        }
    }
}

private extension HexColor {
    /// The color at full opacity. A clear color stays clear: a see-through strip shows the surface `BarSurface` puts under
    /// it, and a popup hides its background while a morph card draws it.
    var opaque: HexColor {
        HexColor(light: light & 0xff == 0 ? light : light | 0xff, dark: dark & 0xff == 0 ? dark : dark | 0xff)
    }

    func faded(_ opacity: Double) -> HexColor {
        func fade(_ rgba: UInt32) -> UInt32 { rgba & ~0xff | UInt32((Double(rgba & 0xff) * opacity).rounded()) }
        return HexColor(light: fade(light), dark: fade(dark))
    }
}

extension WidgetAppearance {
    /// Increase Contrast outlines tiles and popups in their text color, which the theme pairs with their background.
    func border(increasedContrast: Bool) -> Color {
        increasedContrast ? foreground : borderColor
    }
}

/// Paint inside the visible strip; neither border choice contributes to layout or hit testing.
/// Shared with Customize so its theme cards show the same outline as the bar.
struct BarBorder: View {
    let style: WidgetStyle

    var body: some View {
        Group {
            if style.borderEdges == .all {
                RoundedRectangle(cornerRadius: max(0, style.cornerRadius ?? 0))
                    .pixelBorder(style.borderColor?.color ?? .clear, width: max(0, style.borderWidth ?? 0))
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    (style.borderColor?.color ?? .clear).frame(height: max(0, style.borderWidth ?? 0))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
