import SwiftUI

/// The bar building itself on Make it yours' stage, over the stage bar, which shows the person's own bar at its end.
struct SetupDemo: View {
    let timeline: SetupDemoTimeline
    /// The person's configuration, whose look the widgets arrive in.
    let look: Configuration
    /// The themes the bar tries on, at most one for each of `SetupDemoTimeline.looks`.
    let looks: [(name: String, look: Configuration)]
    /// The stage bar's size.
    let size: CGSize
    /// Where each widget sits in the bar, which the blueprint outlines, the group gathers and the pointer clicks.
    @State private var frames: [Part: CGRect] = [:]
    /// The height of each popup the pointer opens.
    @State private var popupHeights: [EssentialsPopup: Double] = [:]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.menuBarScheme) private var menuBarScheme

    enum Part { case workspaces, app, cpu, battery, clock }

    /// The widgets in the order they're drafted and arrive, each with its label and where it rises from.
    private static let parts: [(part: Part, label: String, from: CGSize)] = [
        (.workspaces, "workspaces", CGSize(width: -40, height: 90)), (.app, "active app", CGSize(width: -20, height: 105)),
        (.cpu, "cpu", CGSize(width: 0, height: 115)), (.battery, "battery", CGSize(width: 20, height: 105)),
        (.clock, "clock", CGSize(width: 40, height: 90)),
    ]
    /// The popup each of `SetupDemoTimeline.clicks` opens, and the widget it clicks.
    private static let clicks: [(kind: EssentialsPopup, part: Part)] = [(.clock, .clock), (.system, .cpu), (.battery, .battery)]
    /// When the pointer starts each glide, from below the bar to each widget it clicks and away again, how long it takes,
    /// and how far its path bows.
    private static let glides: [(start: Double, duration: Double, bend: CGSize)] = [
        (6.21, 0.72, CGSize(width: 70, height: 20)), (7.74, 0.59, CGSize(width: 0, height: 26)),
        (9.14, 0.59, CGSize(width: 0, height: 26)), (10.71, 0.63, CGSize(width: -40, height: 0)),
    ]
    private static let headlines = [("Built from widgets.", 0.36, 4.41), ("Arranged your way.", 4.95, 6.21),
                                    ("Click any of them.", 6.75, 10.62), ("Dressed in any theme.", 11.0, 13.4)]
    /// The room the blueprint takes around the bar.
    private static let margin = CGSize(width: 160, height: 150)
    /// The room under the bar that popups and the pointer use.
    private static let below = 560.0
    private static let warm = Color(red: 1, green: 0.8, blue: 0.45)
    private static let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    private static let easeOut = SetupDemoTimeline.easeOut
    private static let easeInOut = SetupDemoTimeline.easeInOut

    private var time: Double { timeline.time }
    private var glass: GlassPalette { GlassPalette(colorScheme) }
    /// The light that clears the widgets as the first theme replaces them.
    private var clearing: Double { looks.isEmpty ? timeline.ownWipe : timeline.wipe(SetupDemoTimeline.looks[0]) }
    /// The blueprint, fading once the widgets are in.
    private var drafted: Double { 1 - Self.easeInOut.value(at: progress(time, 4.5, 0.72)) }
    /// The click whose popup is open, if any.
    private var opened: Int? {
        time < SetupDemoTimeline.closing ? SetupDemoTimeline.clicks.lastIndex { time >= $0 + 0.05 } : nil
    }

    var body: some View {
        let swapped = time >= SetupDemoTimeline.swap
        let order: [Part?] = [.workspaces, .app, nil, swapped ? .battery : .cpu, swapped ? .cpu : .battery, .clock]
        ZStack {
            group.environment(\.colorScheme, scheme(look))
            HStack(spacing: look.bar.spacing + 4) {
                ForEach(order, id: \.self) { part in
                    if let part { widget(part) } else { Spacer(minLength: 0) }
                }
            }
            .lineLimit(1)
            .padding(.horizontal, look.bar.inset + 6)
            .frame(width: size.width, height: size.height)
            .animation(.spring(duration: 0.81, bounce: 0), value: swapped)
            .environment(\.colorScheme, scheme(look))
            morph
        }
        .frame(width: size.width, height: size.height)
        // The blueprint and what shows under and over the bar draw outside its frame, which leaves the frame the bar's,
        // and the widgets' frames in the bar's own coordinates.
        .background {
            ZStack {
                grid
                blueprint
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .topLeading) {
                popups.environment(\.colorScheme, scheme(look))
                pointer
                captions
            }
            .frame(width: size.width, height: size.height + Self.below, alignment: .topLeading)
        }
        .coordinateSpace(.named("demo"))
    }

    /// A fine grid around the bar, lined up with its edges and fading toward its own.
    private var grid: some View {
        let bar = CGRect(origin: CGPoint(x: Self.margin.width, y: Self.margin.height), size: size)
        return Canvas { context, canvas in
            var minor = Path()
            var major = Path()
            for x in stride(from: bar.minX.truncatingRemainder(dividingBy: 16), through: canvas.width, by: 16) {
                let line = CGRect(x: x, y: 0, width: 0.5, height: canvas.height)
                if Int(((x - bar.minX) / 16).rounded()) % 4 == 0 { major.addRect(line) } else { minor.addRect(line) }
            }
            for y in stride(from: bar.minY.truncatingRemainder(dividingBy: 16), through: canvas.height, by: 16) {
                let line = CGRect(x: 0, y: y, width: canvas.width, height: 0.5)
                if Int(((y - bar.minY) / 16).rounded()) % 4 == 0 { major.addRect(line) } else { minor.addRect(line) }
            }
            context.fill(minor, with: .color(glass.blueprint.opacity(0.07)))
            context.fill(major, with: .color(glass.blueprint.opacity(0.14)))
        }
        .frame(width: size.width + 2 * Self.margin.width, height: size.height + 2 * Self.margin.height)
        .mask { EllipticalGradient(colors: [.black, .clear], startRadiusFraction: 0.15, endRadiusFraction: 0.5) }
        .opacity(Self.easeOut.value(at: progress(time, 0.09, 0.99)) * drafted)
    }

    /// The bar drafted: guide lines along its edges drawn out from its middle, its size between two ticks above it, and
    /// each widget's place traced as a dashed outline with a label, until the widget lands in it.
    private var blueprint: some View {
        let frames = frames
        return Canvas { context, canvas in
            let bar = CGRect(origin: CGPoint(x: Self.margin.width, y: Self.margin.height), size: size)
            let thin = StrokeStyle(lineWidth: 1)
            let across = Self.easeInOut.value(at: progress(time, 0.23, 1.13)) * (size.width / 2 + 110)
            let down = Self.easeInOut.value(at: progress(time, 0.63, 0.63)) * (size.height / 2 + 28)
            var guides = Path()
            for y in [bar.minY, bar.maxY] {
                guides.move(to: CGPoint(x: bar.midX - across, y: y))
                guides.addLine(to: CGPoint(x: bar.midX + across, y: y))
            }
            for x in [bar.minX, bar.maxX] {
                guides.move(to: CGPoint(x: x, y: bar.midY - down))
                guides.addLine(to: CGPoint(x: x, y: bar.midY + down))
            }
            context.stroke(guides, with: .color(glass.blueprint.opacity(0.5)), style: thin)

            let y = bar.minY - 24
            let gap = 56.0
            let reach = Self.easeInOut.value(at: progress(time, 0.9, 0.81)) * (size.width / 2 - gap)
            var dimension = Path()
            dimension.move(to: CGPoint(x: bar.midX - gap, y: y))
            dimension.addLine(to: CGPoint(x: bar.midX - gap - reach, y: y))
            dimension.move(to: CGPoint(x: bar.midX + gap, y: y))
            dimension.addLine(to: CGPoint(x: bar.midX + gap + reach, y: y))
            context.stroke(dimension, with: .color(glass.blueprint.opacity(0.8)), style: thin)
            var ticks = context
            ticks.opacity = Self.easeOut.value(at: progress(time, 1.67, 0.27))
            var marks = Path()
            for x in [bar.minX, bar.maxX] {
                marks.move(to: CGPoint(x: x, y: y - 5))
                marks.addLine(to: CGPoint(x: x, y: y + 5))
            }
            ticks.stroke(marks, with: .color(glass.blueprint.opacity(0.8)), style: thin)
            var label = context
            label.opacity = Self.easeOut.value(at: progress(time, 1.17, 0.45))
            label.draw(Text("\(Int(size.width)) × \(Int(size.height)) pt").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(glass.blueprint), at: CGPoint(x: bar.midX, y: y))

            for (index, entry) in Self.parts.enumerated() {
                guard let frame = frames[entry.part]?.offsetBy(dx: bar.minX, dy: bar.minY) else { continue }
                let traced = Self.easeInOut.value(at: progress(time, 1.35 + 0.135 * Double(index), 0.63))
                let filled = progress(time, Self.drop(index) + 0.54, 0.5)
                let outline = Path(roundedRect: frame.insetBy(dx: -3, dy: -3), cornerRadius: 7)
                context.stroke(outline.trimmedPath(from: 0, to: traced), with: .color(glass.blueprint.opacity(0.85 * (1 - filled))),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.stroke(outline, with: .color(Self.warm.opacity(0.9 * sin(.pi * filled))), style: thin)
                // Neighbouring labels alternate in depth, so short widgets' labels don't overlap.
                let depth = index.isMultiple(of: 2) ? 14.0 : 30.0
                var callout = context
                callout.opacity = Self.easeOut.value(at: progress(time, 1.71 + 0.135 * Double(index), 0.4)) * (1 - filled)
                var tick = Path()
                tick.move(to: CGPoint(x: frame.midX, y: bar.maxY + 4))
                tick.addLine(to: CGPoint(x: frame.midX, y: bar.maxY + depth))
                callout.stroke(tick, with: .color(glass.blueprint.opacity(0.6)), style: thin)
                callout.draw(Text(entry.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(glass.blueprint),
                             at: CGPoint(x: frame.midX, y: bar.maxY + depth + 3), anchor: .top)
            }
        }
        .frame(width: size.width + 2 * Self.margin.width, height: size.height + 2 * Self.margin.height)
        .opacity(drafted)
    }

    /// When the `index`th widget drafted starts to rise into its place.
    private static func drop(_ index: Int) -> Double {
        2.88 + 0.162 * Double(index)
    }

    /// A widget rising into its drafted place on a long ease-out, keeping its shape; it arcs over its neighbour when two
    /// swap, and fades as the first theme's light crosses it.
    private func widget(_ part: Part) -> some View {
        let index = Self.parts.firstIndex { $0.part == part }!
        let from = Self.parts[index].from
        let arrived = Self.easeOut.value(at: progress(time, Self.drop(index), 0.9))
        let shown = Self.easeOut.value(at: progress(time, Self.drop(index), 0.4))
        let hop = sin(.pi * Self.easeInOut.value(at: progress(time, SetupDemoTimeline.swap, 0.81)))
        let lift = part == .cpu ? -14 * hop : part == .battery ? 8 * hop : 0
        let center = (frames[part]?.midX ?? size.width / 2) / size.width
        let gone = progress(clearing * 1.25 - 0.125, center - 0.06, 0.12)
        return content(part)
            .fixedSize()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("demo")) } action: { frames[part] = $0 }
            .offset(x: from.width * (1 - arrived), y: from.height * (1 - arrived) + lift)
            .opacity(shown * (1 - gone))
    }

    @ViewBuilder private func content(_ part: Part) -> some View {
        let sample = ThemeSampleBar(look: look)
        switch part {
        case .workspaces:
            sample.workspaces(active: 1, style: resolveStyle([look.defaults]))
        case .app:
            sample.tile(role: .primary) {
                HStack(spacing: 6) {
                    Image(nsImage: Self.finder).resizable().frame(width: 16, height: 16)
                    Text("Finder")
                }
            }
        case .cpu:
            sample.tile(role: .value) {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                    Text("14%").monospacedDigit()
                }
            }
        case .battery:
            sample.tile(role: .value) { sample.battery }
        case .clock:
            sample.tile(role: .time) { Text(Date.now, format: .dateTime.weekday().day().month().hour().minute()) }
        }
    }

    /// The right widgets gathering into a group, which settles in around them once they've swapped.
    @ViewBuilder private var group: some View {
        if let cpu = frames[.cpu], let battery = frames[.battery], let clock = frames[.clock] {
            let bounds = cpu.union(battery).union(clock).insetBy(dx: -6, dy: -3)
            let gathered = Self.easeOut.value(at: progress(time, SetupDemoTimeline.group, 0.63))
            let gone = progress(clearing * 1.25 - 0.125, bounds.midX / size.width - 0.06, 0.12)
            RoundedRectangle(cornerRadius: min(bounds.height / 2, 10))
                .fill(.primary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: min(bounds.height / 2, 10)).strokeBorder(.primary.opacity(0.18)))
                .frame(width: bounds.width, height: bounds.height)
                .scaleEffect(1.04 - 0.04 * gathered)
                .opacity(gathered * (1 - gone))
                .position(x: bounds.midX, y: bounds.midY)
        }
    }

    /// Where the popup of the `click`th click sits: centred under its widget as far as the bar allows, `popupOffset`
    /// below the bar.
    private func box(_ click: Int) -> CGRect? {
        let (kind, part) = Self.clicks[click]
        guard let widget = frames[part], let height = popupHeights[kind] else { return nil }
        let width = kind.popup(timeZone: nil).style.width!
        let left = min(max(widget.midX - width / 2, 8), size.width - width - 8)
        return CGRect(x: left, y: size.height - look.bar.verticalMargin + look.bar.popupOffset, width: width, height: height)
    }

    /// The popup the pointer's clicks open, with the bar's popup motion and transition. A click on another widget while
    /// it's open moves it there as the bar does: a card with the popup's background travels between their places while
    /// their contents cross-fade, or, without morphing, one popup closes and the next opens.
    private var popups: some View {
        let sample = ThemeSampleBar(look: look)
        let opened = opened
        let animation = look.bar.motion.popupAnimation
        return ZStack(alignment: .topLeading) {
            if let opened, let card = box(opened), let widget = frames[Self.clicks[opened].part] {
                let style = sample.popupStyle(Self.clicks[opened].kind).resolved(for: StyleStates())
                let radius = WidgetAppearance(style, defaults: WidgetStyle(spacing: PopupConfiguration.blockSpacing)).cornerRadius
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: card.width, height: card.height)
                        .modifier(PopupBackground(style: style, glass: look.bar.glass, backgrounds: PopupBackgrounds()))
                        .offset(x: card.minX, y: card.minY)
                    ForEach(Self.clicks.indices, id: \.self) { index in
                        if let place = box(index) {
                            sample.popup(Self.clicks[index].kind)
                                .fixedSize()
                                .offset(x: place.minX, y: place.minY)
                                .opacity(index == opened ? 1 : 0)
                                .animation(index == opened ? .easeOut(duration: 0.6 * animation.duration).delay(0.2 * animation.duration)
                                    : .easeOut(duration: 0.4 * animation.duration), value: opened)
                        }
                    }
                }
                .frame(width: size.width, height: size.height + Self.below, alignment: .topLeading)
                .mask(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: radius).frame(width: card.width, height: card.height).offset(x: card.minX, y: card.minY)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                .id(look.bar.morphPopups ? nil : opened)
                .transition(transition(at: UnitPoint(x: widget.midX / size.width, y: card.minY / (size.height + Self.below))))
            }
        }
        .frame(width: size.width, height: size.height + Self.below, alignment: .topLeading)
        .animation(animation.value, value: opened)
        .background {
            ForEach(Self.clicks, id: \.kind) { click in
                sample.popup(click.kind)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { popupHeights[click.kind] = $0 }
            }
        }
    }

    /// How the bar's popup transition opens and closes a popup whose top edge is at `edge`'s height, below the widget at
    /// `edge`'s width.
    private func transition(at edge: UnitPoint) -> AnyTransition {
        switch look.bar.popupTransition ?? look.bar.motion.popupTransition {
        case .fade: .opacity.combined(with: .scale(scale: 0.97, anchor: edge))
        case .zoom: .opacity.combined(with: .scale(scale: 0.5, anchor: edge))
        case .slide: .opacity.combined(with: .offset(y: -12))
        case .unfold: .opacity.combined(with: .modifier(active: Unfolding(shown: 0, edge: edge), identity: Unfolding(shown: 1, edge: edge)))
        }
    }

    /// The pointer gliding in on a curve, clicking each widget with a ripple, its tip on the widget's middle, and gliding
    /// away.
    @ViewBuilder private var pointer: some View {
        let targets = Self.clicks.compactMap { frames[$0.part] }.map { CGPoint(x: $0.midX, y: $0.midY) }
        if targets.count == Self.clicks.count {
            let stops = [CGPoint(x: targets[0].x + 120, y: size.height + 190)] + targets
                + [CGPoint(x: targets[targets.count - 1].x + 140, y: size.height + 230)]
            let tip = Self.glides.indices.filter { time >= Self.glides[$0].start }.last.map { index in
                let glide = Self.glides[index]
                return Self.curve(stops[index], stops[index + 1], bend: glide.bend,
                                  Self.easeInOut.value(at: progress(time, glide.start, glide.duration)))
            } ?? stops[0]
            let press = SetupDemoTimeline.clicks.map { sin(.pi * progress(time, $0 - 0.06, 0.22)) }.max()!
            ForEach(targets.indices, id: \.self) { index in
                let ripple = Self.easeOut.value(at: progress(time, SetupDemoTimeline.clicks[index], 0.5))
                Circle()
                    .strokeBorder(glass.ink.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 10 + 36 * ripple, height: 10 + 36 * ripple)
                    .opacity(ripple > 0 && ripple < 1 ? 1 - ripple : 0)
                    .position(targets[index])
            }
            let arrow = NSCursor.arrow
            // The arrow's hot spot, measured from its image's top left, is its tip.
            Image(nsImage: arrow.image)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                .scaleEffect(1 - 0.15 * press, anchor: UnitPoint(x: arrow.hotSpot.x / arrow.image.size.width, y: arrow.hotSpot.y / arrow.image.size.height))
                .position(x: tip.x + arrow.image.size.width / 2 - arrow.hotSpot.x, y: tip.y + arrow.image.size.height / 2 - arrow.hotSpot.y)
                .opacity(Self.easeOut.value(at: progress(time, Self.glides[0].start, 0.36)) * (1 - progress(time, 11.07, 0.36)))
        }
    }

    /// A point `t` of the way along a gentle curve from `a` to `b`, bowed by `bend` at its middle.
    private static func curve(_ a: CGPoint, _ b: CGPoint, bend: CGSize, _ t: Double) -> CGPoint {
        let control = CGPoint(x: (a.x + b.x) / 2 + bend.width, y: (a.y + b.y) / 2 + bend.height)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x, y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
    }

    /// The headlines where Make it yours' title will be, and each theme's name under the bar as it tries it on.
    private var captions: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.headlines, id: \.0) { text, start, end in
                if time >= start && time < end + 0.35 {
                    headline(text, start: start, end: end).position(x: size.width / 2, y: -102)
                }
            }
            ForEach(looks.indices, id: \.self) { index in
                let starts = SetupDemoTimeline.looks
                let next = index + 1 < looks.count ? starts[index + 1] : SetupDemoTimeline.own
                Text(looks[index].name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(glass.ink.opacity(0.7))
                    .opacity(Self.easeOut.value(at: progress(time, starts[index] + 0.45, 0.35)) * (1 - progress(time, next, 0.25)))
                    .position(x: size.width / 2, y: size.height + 44)
            }
        }
    }

    /// The bar morphing from the built widgets into each theme it tries on. The stage bar draws the last light, which
    /// shows the person's own bar.
    @ViewBuilder private var morph: some View {
        let starts = SetupDemoTimeline.looks.prefix(looks.count) + [SetupDemoTimeline.own]
        if let step = starts.lastIndex(where: { time >= $0 }) {
            let from = step == 0 ? nil : looks[step - 1].look
            let to = step < looks.count ? looks[step].look : nil
            let morphed = timeline.wipe(starts[step])
            let (a, b) = (strip(from ?? look), strip(to ?? look))
            let rect = CGRect(x: Self.mix(a.rect.minX, b.rect.minX, morphed), y: Self.mix(a.rect.minY, b.rect.minY, morphed),
                              width: Self.mix(a.rect.width, b.rect.width, morphed), height: Self.mix(a.rect.height, b.rect.height, morphed))
            let radius = Self.mix(a.radius, b.radius, morphed)
            ZStack(alignment: .topLeading) {
                if let from { card(from, in: rect, radius: radius, shown: 1 - morphed, wipe: morphed, showing: false) }
                if let to { card(to, in: rect, radius: radius, shown: morphed, wipe: morphed, showing: true) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // The stage bar draws the light that shows the person's own bar.
            if to != nil { light(morphed) }
        }
    }

    /// `look`'s strip at `rect` while the bar morphs, its fill and border `shown` of the way in, and its widgets showing,
    /// or left, where the light has passed.
    private func card(_ look: Configuration, in rect: CGRect, radius: Double, shown: Double, wipe: Double, showing: Bool) -> some View {
        let sample = ThemeSampleBar(look: look)
        return ZStack {
            RoundedRectangle(cornerRadius: radius).fill(sample.background).opacity(shown)
            BarBorder(style: sample.barStyle).opacity(shown)
            sample.row.mask { Self.wipe(wipe, showing: showing) }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .environment(\.colorScheme, scheme(look))
    }

    /// The light or dark side `look` shows, as the stage bar shows it.
    private func scheme(_ look: Configuration) -> ColorScheme {
        look.bar.colorScheme(menuBar: menuBarScheme, system: colorScheme)
    }

    /// Where `look` puts the bar's strip in the stage bar, and its corner radius, at most half its height.
    private func strip(_ look: Configuration) -> (rect: CGRect, radius: Double) {
        let sample = ThemeSampleBar(look: look)
        let height = sample.stripHeight
        return (CGRect(x: look.bar.horizontalMargin, y: (size.height - height) / 2, width: size.width - 2 * look.bar.horizontalMargin, height: height),
                min(sample.barStyle.cornerRadius ?? 0, height / 2))
    }

    private static func mix(_ a: Double, _ b: Double, _ amount: Double) -> Double {
        a + (b - a) * amount
    }

    /// The light crossing the bar as a theme wipes in behind it.
    private func light(_ wipe: Double) -> some View {
        LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: Self.warm, location: 0.5), .init(color: .clear, location: 0.6)],
                       startPoint: UnitPoint(x: wipe * 1.25 - 0.625, y: 0), endPoint: UnitPoint(x: wipe * 1.25 + 0.375, y: 0))
            .blendMode(.plusLighter)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(wipe > 0 && wipe < 1 ? 0.7 : 0)
    }

    /// What a light `wipe` of the way across the bar shows of the look behind it, or leaves of the look before it.
    private static func wipe(_ wipe: Double, showing: Bool) -> LinearGradient {
        LinearGradient(colors: showing ? [.black, .clear] : [.clear, .black], startPoint: UnitPoint(x: wipe * 1.25 - 0.25, y: 0),
                       endPoint: UnitPoint(x: wipe * 1.25, y: 0))
    }

    /// A headline whose words rise into place one after another, then lift away.
    private func headline(_ text: String, start: Double, end: Double) -> some View {
        let words = text.split(separator: " ")
        let out = Self.easeInOut.value(at: progress(time, end, 0.35))
        return HStack(spacing: 9) {
            ForEach(words.indices, id: \.self) { index in
                let shown = Self.easeOut.value(at: progress(time, start + Double(index) * 0.07, 0.6))
                Text(words[index])
                    .opacity(shown)
                    .offset(y: 12 * (1 - shown))
            }
        }
        .font(.system(size: 40, weight: .semibold))
        .tracking(-0.8)
        .foregroundStyle(glass.ink)
        .fixedSize()
        .opacity(1 - out)
        .offset(y: -8 * out)
    }
}

/// A popup unfolding down from its top edge, at `edge`'s height, as the bar's `unfold` popup transition shows it.
private struct Unfolding: ViewModifier, Animatable {
    var shown: Double
    let edge: UnitPoint

    nonisolated var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        content.mask { Rectangle().scaleEffect(x: 1, y: shown, anchor: UnitPoint(x: 0.5, y: edge.y)) }
    }
}
