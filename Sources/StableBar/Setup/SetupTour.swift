import ServiceManagement
import SwiftUI

struct SetupTourView: View {
    @Bindable var session: SetupSession
    /// The display setup shows on, which decides where its bar sits.
    let display: BarDisplay
    /// Reads the height of that display's macOS menu bar, which changes when setup hides or shows it.
    let menuBarHeight: () -> Double
    /// The height the Dock takes at the bottom of the screen. The tour lays out above it.
    let dock: Double
    /// The tour's backdrop, made from `wallpaper` when StableBar can read it.
    let backdrop: SetupBackdrop
    let wallpaper: URL?
    /// Closes setup, once it's finished or to skip it.
    let close: () -> Void
    /// Puts the tour over the macOS menu bar, which it covers until the bar takes the menu bar's place, under the bar
    /// once it's there, or under System Settings.
    let cover: () -> Void
    let reveal: () -> Void
    let lower: () -> Void
    let editBar: (() -> Void)?
    /// Whether the person opened setup from Settings, Help or the menu rather than at launch, which skips the bar's
    /// arrival at Make it yours.
    let reopened: Bool
    /// When the intro started, once the backdrop was ready.
    @State private var opened: Date?
    /// Whether the intro has played to its end or been skipped.
    @State private var settled: Bool
    /// When Get Started was clicked, while the bar arrives at Make it yours.
    @State private var departed: Date?
    /// The themes the bar tries on as it builds itself, kept from Get Started on: previews read partway would start a
    /// later morph without the earlier one.
    @State private var demoLooks: [(name: String, look: Configuration)] = []
    /// Whether the bar's copy has left the stage for the bar's place, once macOS has answered for Automation.
    @State private var flown: Bool
    /// Whether the copy's flight has ended, which Finish setup waits for so the bar doesn't jump to its place.
    @State private var arrived: Bool
    /// Counts Back, so that a flight Back interrupted doesn't set `arrived` when it ends during a later one.
    @State private var backs = 0
    /// Whether the bar itself has taken over from its copy: in the menu bar's place, or below it at Finish setup.
    @State private var landed: Bool
    /// System Settings or a prompt is in front of the tour, so the real bar stays covered until the tour is back.
    @State private var lowered = false
    @State private var confirmingSkip = false
    @State private var reviewIsWorking = false
    @State private var showsSuggestions = false
    /// The height of Allow's card, which centers Allow on the screen with the bar above it.
    @State private var allowCardHeight = 300.0
    /// The height of Make it yours' themes, which scroll with the presets when they would reach the toolbar.
    @State private var themesHeight = 114.0
    @State private var managerGap: ManagerGap?
    /// The menu bar's height as last read, so the bar's place follows it when the menu bar hides or shows.
    @State private var currentMenuBarHeight: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The date scenes draw at, which shows every animation finished.
    @Environment(\.fixedDate) private var fixedDate
    @Environment(\.sceneWallpaper) private var sceneWallpaper
    @Environment(\.displayScale) private var displayScale

    private var motion: SetupMotion { SetupMotion(reduceMotion: reduceMotion) }
    /// The copy's flight to the bar's place. It ends exactly on time, unlike a spring, so the bar takes over from the
    /// copy where the copy rests.
    private var flightDuration: Double { reduceMotion ? 0.35 : 0.9 }
    private var flight: Animation {
        reduceMotion ? .easeInOut(duration: flightDuration) : .timingCurve(0.2, 0.9, 0.2, 1, duration: flightDuration)
    }
    private static let warm = Color(red: 1, green: 0.8, blue: 0.45)
    private static let gold = Color(red: 0.847, green: 0.698, blue: 0.369)
    private static let wordmark = Font(shantellSans("shantell-sans-display", size: 76))
    private static let handwriting = Font(shantellSans("shantell-sans-hand", size: 22))
    private static let glow = LinearGradient(colors: [.clear, .orange, warm, .orange, .clear], startPoint: .leading, endPoint: .trailing)

    init(session: SetupSession, display: BarDisplay, menuBarHeight: @escaping () -> Double, dock: Double, backdrop: SetupBackdrop,
         wallpaper: URL?, close: @escaping () -> Void, cover: @escaping () -> Void, reveal: @escaping () -> Void,
         lower: @escaping () -> Void, editBar: (() -> Void)?, reopened: Bool = false) {
        _session = Bindable(session)
        self.display = display
        self.menuBarHeight = menuBarHeight
        _currentMenuBarHeight = State(initialValue: menuBarHeight())
        self.dock = dock
        self.backdrop = backdrop
        self.wallpaper = wallpaper
        self.close = close
        self.cover = cover
        self.reveal = reveal
        self.lower = lower
        self.editBar = editBar
        self.reopened = reopened
        _settled = State(initialValue: session.step != .intro)
        _flown = State(initialValue: session.step == .done)
        _arrived = State(initialValue: session.step == .done)
        _landed = State(initialValue: session.step == .done)
    }

    /// Where the bar sits on a display of `size`, measured down from its top.
    private func barFrame(in size: CGSize) -> CGRect {
        guard let configuration = session.store.configuration else { return .zero }
        let frame = configuration.onScreen(ScreenKind(display)).bar.frame(height: configuration.barGeometry(for: display).layoutHeight,
                                                                           on: CGRect(origin: .zero, size: size), menuBar: currentMenuBarHeight)
        return CGRect(x: 0, y: size.height - frame.maxY, width: size.width, height: frame.height)
    }

    /// The width the bar is laid out at on the stage.
    private func stageWidth(_ size: CGSize) -> Double { min(size.width - 112, 1400) }

    /// The height Make it yours keeps for the bar: the tallest theme's, so choosing a theme doesn't move the page.
    private func stageHeight(_ bar: CGRect) -> Double {
        session.themePreviews.values.map { $0.configuration(for: barAppearance).bar.height }.reduce(bar.height, max)
    }

    /// The top of a group `height` high, a little above the middle of the space above the toolbar. It leaves out the
    /// menu bar, which the bar takes the place of while Allow shows, so the group stays still as it does.
    private func groupTop(_ size: CGSize, height: Double) -> Double {
        max(24, (size.height - dock - 96 - height) * 0.44)
    }

    /// The tops of Make it yours' title, presets and themes, and the middle of the bar between the title and the
    /// presets.
    private func chooseLayout(_ size: CGSize, bar: Double) -> (title: Double, bar: Double, presets: Double, themes: Double) {
        let title = groupTop(size, height: 78 + 48 + bar + 52 + 98 + 30 + 114)
        let presets = title + 78 + 48 + bar + 52
        return (title, title + 126 + bar / 2, presets, presets + 98 + 30)
    }

    /// The tops of Allow's title and card, and the middle of the bar between them, smaller than on Make it yours, where
    /// it waits until macOS has answered for Automation.
    private func allowLayout(_ size: CGSize, bar: Double) -> (title: Double, bar: Double, card: Double) {
        let title = groupTop(size, height: 84 + bar * 0.68 + 36 + allowCardHeight)
        return (title, title + 84 + bar * 0.68 / 2, title + 84 + bar * 0.68 + 36)
    }

    /// Where the bar sits on each step: its middle, the width it's laid out at, and its scale. On Allow it's laid out at the
    /// screen's width already, so its flight to its place moves and scales it without laying it out again each frame.
    private func pose(in size: CGSize, bar: CGRect) -> (center: CGPoint, width: Double, scale: Double) {
        switch session.step {
        case .intro: (CGPoint(x: size.width / 2, y: size.height * 0.5), stageWidth(size), 0.72)
        case .choose: (CGPoint(x: size.width / 2, y: chooseLayout(size, bar: stageHeight(bar)).bar), stageWidth(size), 1)
        case .allow where !flown: (CGPoint(x: size.width / 2, y: allowLayout(size, bar: bar.height).bar), size.width, 0.68 * stageWidth(size) / size.width)
        case .allow, .done: (CGPoint(x: bar.midX, y: bar.midY), size.width, 1)
        }
    }

    /// The Mac's appearance, which the wallpaper and the tour follow.
    private var macScheme: ColorScheme {
        session.store.configurationStore.context.appearance == "dark" ? .dark : .light
    }

    private var glass: GlassPalette { GlassPalette(macScheme) }

    /// The look a bar that follows the wallpaper takes on the stage: its menu bar's over the Mac's wallpaper, or dark,
    /// for contrast, over StableBar's own.
    private var stageMenuBarScheme: ColorScheme? {
        backdrop.images?.bundled == true ? .dark : MenuBarAppearance.shared.schemes[display.id]
    }

    private var barAppearance: BarAppearance {
        session.store.configuration?.bar.appearance ?? (macScheme == .dark ? .dark : .light)
    }

    /// The side a tile draws its theme in: a theme that follows the wallpaper takes the stage bar's.
    private func tileAppearance(_ choice: ThemeChoice) -> BarAppearance {
        guard session.store.configuration?.bar.appearance == nil,
              session.themePreviews[choice.key]?.configuration(for: barAppearance).bar.followsWallpaper == true,
              let scheme = stageMenuBarScheme else { return barAppearance }
        return scheme == .dark ? .dark : .light
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bar = barFrame(in: size)
            TimelineView(.animation(paused: fixedDate != nil || opened == nil || (session.step != .intro || settled) && departed == nil)) { context in
                let intro = SetupIntro(reduceMotion: reduceMotion,
                                       time: fixedDate != nil || settled ? 60 : opened.map { context.date.timeIntervalSince($0) } ?? 0)
                let demo = SetupDemoTimeline(time: departed.map { context.date.timeIntervalSince($0) } ?? 60)
                ZStack {
                    background(size: size, intro: intro)
                    if session.step == .intro {
                        introduction(size: size, intro: intro)
                    }
                    if !landed {
                        stageBar(size: size, bar: bar, intro: intro, demo: demo)
                    }
                    if session.step == .done {
                        Rectangle()
                            .fill(Self.glow)
                            .frame(width: size.width * (landed || reduceMotion ? 1 : 0), height: 2)
                            .background(Rectangle().fill(Self.glow).frame(height: 8).blur(radius: 12))
                            .opacity(landed ? 0.85 : 0)
                            .position(x: size.width / 2, y: bar.maxY)
                            .accessibilityHidden(true)
                    }
                }
            }
            ZStack {
                if session.step == .choose && departed == nil {
                    choose(size: size, bar: bar)
                }
                if departed != nil {
                    Button(action: endDemo) { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Skip")
                }
                if session.step == .allow {
                    allow(size: size, bar: bar)
                }
                if session.step == .done && landed {
                    done
                        .position(x: size.width / 2, y: size.height * 0.42)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -16)).combined(with: .scale(scale: 0.94, anchor: .top)))
                }
                if [.choose, .allow].contains(session.step) && departed == nil {
                    toolbar.position(x: size.width / 2, y: size.height - dock - 74).transition(.opacity)
                }
                GlassCloseButton(title: cornerSaves ? "Done" : "Skip setup", action: skip)
                    .background(glass.backing, in: Circle())
                    .position(x: size.width - 38, y: (flown ? bar.maxY : 0) + 38)
                    .opacity(session.step == .intro && !settled && fixedDate == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.4), value: settled)
            }
            .disabled(confirmingSkip || session.applicationMove.isBusy || session.review != nil
                      || session.step == .done && session.placementSettling)
            if let review = session.review {
                suggestionReview(review).transition(.opacity)
            }
            if confirmingSkip {
                skipConfirmation.transition(.opacity)
            }
            Color.clear
                .task(id: macScheme) {
                    let scene = sceneWallpaper?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    await backdrop.load(scene.map(SetupBackdrop.Wallpaper.image) ?? wallpaper.map(SetupBackdrop.Wallpaper.file),
                                        pixels: CGSize(width: size.width * displayScale, height: size.height * displayScale), dark: macScheme == .dark)
                    // A load for a newer appearance cancels this one and waits out what's left of the intro.
                    guard !Task.isCancelled else { return }
                    let start = opened ?? .now
                    opened = start
                    let left = SetupIntro(reduceMotion: reduceMotion, time: 0).length - Date.now.timeIntervalSince(start)
                    do { try await Task.sleep(for: .seconds(left)) } catch { return }
                    settled = true
                }
                .task(id: departed) {
                    guard departed != nil else { return }
                    try? await Task.sleep(for: .seconds(SetupDemoTimeline.length))
                    endDemo()
                }
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, macScheme)
        .foregroundStyle(glass.ink)
        .animation(.easeOut(duration: 0.2), value: confirmingSkip)
        .animation(.easeOut(duration: 0.2), value: session.review == nil)
        // The bar moves when macOS hides or shows its menu bar, which the screen's parameters announce a moment after
        // setup's own change lands.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            currentMenuBarHeight = menuBarHeight()
        }
        .onChange(of: session.menuBarHides) { currentMenuBarHeight = menuBarHeight() }
        .onChange(of: reduceMotion) { if reduceMotion { endDemo() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshAccess()
            lowered = false
            // Back from System Settings, the tour covers the menu bar again, or goes under the bar once it's in place.
            if [.allow, .done].contains(session.step) { if landed { reveal() } else { cover() } }
        }
        // Once Accessibility is allowed in System Settings, macOS brings back the app that was in front before
        // StableBar, over setup.
        .onChange(of: session.accessibilityAccess) {
            guard session.accessibilityAccess && session.step == .allow else { return }
            lowered = false
            if landed { reveal() } else { cover() }
            NSApp.activate(ignoringOtherApps: true)
        }
        // Once macOS has answered for Automation, the bar's copy leaves Allow's stage for the bar's place.
        .onChange(of: session.step == .allow && placementAnswered, initial: true) { _, answered in
            guard answered && !flown else { return }
            let backs = backs
            withAnimation(flight) { flown = true } completion: { if backs == self.backs { arrived = true } }
        }
        // In the menu bar's place, the bar itself takes over from its copy once the copy has arrived.
        .task(id: session.step == .allow && flown && session.placementPhase == .placed(.top)) {
            guard session.step == .allow && flown && session.placementPhase == .placed(.top) && !landed else { return }
            try? await Task.sleep(for: .seconds(flightDuration))
            guard !Task.isCancelled else { return }
            // While System Settings is in front, the tour stays under it until StableBar is active again.
            if !lowered { reveal() }
            landed = true
        }
        .onChange(of: flown, initial: true) {
            let covered = flown ? nil : display.id
            if session.store.barEditing.setupCoversDisplay != covered { session.store.barEditing.setupCoversDisplay = covered }
        }
        // On Allow, the bar draws under the tour once the move there has settled, so its first draw, which starts its
        // widgets, doesn't hold up its copy's flight.
        .task(id: session.step == .allow && !lowered) {
            guard session.step == .allow && !lowered else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !flown else { return }
            session.store.barEditing.setupCoversDisplay = nil
        }
        .onChange(of: session.review == nil) { if session.review != nil { showsSuggestions = false } }
        .task {
            while !Task.isCancelled {
                session.pollAccessibility()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            await session.loadStoreWidgets()
            await session.loadSuggestions()
        }
        .task { await session.loadThemePreviews() }
    }

    /// The wallpaper, sharp as it fades in and settles, then soft and veiled behind the tour, gone once the bar is in
    /// its place.
    private func background(size: CGSize, intro: SetupIntro) -> some View {
        ZStack {
            if let images = backdrop.images {
                Image(decorative: images.sharp, scale: 1).resizable().opacity(intro.wallpaper)
                Image(decorative: images.soft, scale: 1).resizable().interpolation(.high).opacity(intro.softness)
                glass.veil.opacity(intro.softness)
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(intro.zoom)
        .opacity(session.step == .done ? 0 : 1)
        .clipped()
        .accessibilityHidden(true)
    }

    /// StableBar's name over the bar, and what it is under it, with Get Started. A click or Return during the intro
    /// skips to its end.
    private func introduction(size: CGSize, intro: SetupIntro) -> some View {
        let center = pose(in: size, bar: barFrame(in: size)).center
        let wordmark = Text("StableBar").font(Self.wordmark).tracking(intro.nameSpread)
        return ZStack {
            if !settled {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: settle)
            }
            wordmark
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: Self.warm, location: 0.5), .init(color: .clear, location: 0.6)],
                                   startPoint: UnitPoint(x: 2 * intro.sweep - 1, y: 0), endPoint: UnitPoint(x: 2 * intro.sweep, y: 0))
                        .mask(wordmark)
                        .opacity(intro.sweep > 0 && intro.sweep < 1 ? 1 : 0)
                }
                .blur(radius: intro.nameBlur)
                .offset(y: intro.nameRise)
                .opacity(intro.name)
                .position(x: size.width / 2, y: center.y - 112)
            Text("A native, configurable bar for your Mac.")
                .font(Self.handwriting)
                .foregroundStyle(glass.tagline)
                .opacity(intro.invitation)
                .offset(y: reduceMotion ? 0 : 8 * (1 - intro.invitation))
                .position(x: size.width / 2, y: center.y + 62)
            Button { if settled { start() } else { settle() } } label: {
                HStack(spacing: 9) {
                    Text("Get Started")
                    Image(systemName: "arrow.right")
                }
                .frame(minWidth: 132)
            }
            .buttonStyle(GlassButtonStyle(selected: true, size: .large))
            .keyboardShortcut(.defaultAction)
            .opacity(intro.action)
            .offset(y: intro.actionRise)
            .position(x: size.width / 2, y: size.height - dock - 150)
        }
        .transition(.opacity.animation(.easeOut(duration: 0.3)))
    }

    private func settle() {
        withAnimation(.easeOut(duration: 0.35)) { settled = true }
    }

    /// Whether macOS has answered for Automation, or the menu bar didn't need to change, so the bar can leave the stage.
    private var placementAnswered: Bool {
        switch session.placementPhase {
        case .placed, .awaitingAccess, .failed: true
        default: false
        }
    }

    /// Leaves the intro: the bar rises to the stage and builds itself again before the choices arrive, unless setup was
    /// reopened.
    private func start() {
        if !reopened && !reduceMotion {
            demoLooks = availableDemoLooks
            departed = .now
        }
        withAnimation(departed == nil ? motion.stageAnimation : .spring(duration: 0.8, bounce: 0)) { session.step = .choose }
    }

    /// Ends the bar building itself, at its end or at a click or Return, and lets Make it yours' choices arrive.
    private func endDemo() {
        withAnimation(.easeOut(duration: 0.3)) { departed = nil }
    }

    /// The themes the bar tries on as it builds itself: the first two besides the chosen one.
    private var availableDemoLooks: [(name: String, look: Configuration)] {
        let selected = session.store.configurationStore.selectedThemeKey
        let looks = session.themes.filter { $0.key != selected }.compactMap { choice in
            session.themePreviews[choice.key].map { (name: choice.title, look: $0.configuration(for: barAppearance)) }
        }
        return Array(looks.prefix(SetupDemoTimeline.looks.count))
    }

    /// The bar as it is now: it opens out of a glowing line in the intro, its widgets showing as a light crosses it, waits
    /// on the stage over the top of the wallpaper, and flies to its place once macOS has answered for Automation.
    private func stageBar(size: CGSize, bar: CGRect, intro: SetupIntro, demo: SetupDemoTimeline) -> some View {
        let pose = pose(in: size, bar: bar)
        let staged = !flown
        let notch = display.notch.map { $0.upperBound - $0.lowerBound }
        let widgets = departed == nil ? intro.widgets : demo.ownWipe
        return ZStack {
            if session.step == .intro {
                Rectangle()
                    .fill(Self.glow)
                    .frame(width: pose.width * pose.scale * intro.line, height: 2)
                    .background(Rectangle().fill(Self.glow).frame(height: 10).blur(radius: 10))
                    .opacity(intro.glow)
                    .position(pose.center)
            }
            if departed != nil {
                Rectangle()
                    .fill(Self.glow)
                    .frame(width: pose.width * demo.line, height: 2)
                    .background(Rectangle().fill(Self.glow).frame(height: 8).blur(radius: 12))
                    .opacity(demo.glow)
                    .position(x: pose.center.x, y: pose.center.y + bar.height / 2)
            }
            ZStack {
                if let images = backdrop.images {
                    Image(decorative: images.soft, scale: 1).resizable().interpolation(.high).scaledToFill()
                        .frame(width: pose.width, height: bar.height, alignment: .top)
                        .clipped()
                        .opacity(staged ? 1 : 0)
                }
                BarView(store: session.store, display: flown ? display : BarDisplay(id: display.id, isBuiltIn: display.isBuiltIn, isMain: display.isMain,
                                                                                 notch: notch.map { (pose.width - $0) / 2...(pose.width + $0) / 2 },
                                                                                 isPortrait: display.isPortrait), preview: true)
                    .environment(\.colorScheme, macScheme)
                    .environment(\.sampleAppMenus, session.sampleAppMenus)
                    .opacity(demo.ownShown)
                    .mask {
                        LinearGradient(colors: [.black, .clear], startPoint: UnitPoint(x: widgets * 1.25 - 0.25, y: 0),
                                       endPoint: UnitPoint(x: widgets * 1.25, y: 0))
                    }
                LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: Self.warm, location: 0.5), .init(color: .clear, location: 0.6)],
                               startPoint: UnitPoint(x: widgets * 1.25 - 0.625, y: 0), endPoint: UnitPoint(x: widgets * 1.25 + 0.375, y: 0))
                    .blendMode(.plusLighter)
                    .opacity(widgets > 0 && widgets < 1 ? 0.7 : 0)
            }
            .frame(width: pose.width, height: bar.height)
            .clipShape(RoundedRectangle(cornerRadius: staged ? 14 : 0))
            .overlay(RoundedRectangle(cornerRadius: staged ? 14 : 0).pixelBorder(.white.opacity(staged ? 0.18 : 0), width: 1))
            .shadow(color: glass.shadow.opacity(staged ? 0.45 : 0), radius: 35, y: 15)
            .scaleEffect(x: 1, y: intro.open)
            .opacity(intro.bar)
            .scaleEffect(pose.scale)
            .position(pose.center)
            // Below the menu bar, the copy follows the bar up when macOS allows Automation after all.
            .animation(flown ? motion.movement(flight) : nil, value: bar.minY)
            // Allow's card is measured once it lays out, a frame into the move there, so the bar keeps springing toward
            // its place under the card's real height instead of jumping there.
            .animation(motion.movement(motion.stageAnimation), value: allowCardHeight)
            // Make it yours keeps the tallest theme's height for the bar, known once the themes are read, which can be during
            // the move there.
            .animation(motion.movement(motion.stageAnimation), value: stageHeight(bar))
            // With Reduce Motion, the bar fades out of one place and into the next.
            .id(reduceMotion ? "\(session.step)\(flown)" : "stage")
            if departed != nil, let configuration = session.store.configuration {
                SetupDemo(timeline: demo, look: configuration, looks: demoLooks, size: CGSize(width: pose.width, height: bar.height))
                    .environment(\.colorScheme, macScheme)
                    .position(pose.center)
            }
        }
        .environment(\.menuBarScheme, stageMenuBarScheme)
        // Clipping leaves the wallpaper behind the bar hit-testable below it, over the intro's Get Started.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func title(_ text: String, size: Double = 40) -> some View {
        Text(text).font(.system(size: size, weight: .semibold)).tracking(-0.8)
    }

    private func section(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(0.6).foregroundStyle(glass.ink.opacity(0.42))
    }

    /// `content` across the stage's width, its top `y` down the screen.
    private func placed(_ content: some View, y: Double, size: CGSize) -> some View {
        content
            .frame(width: stageWidth(size), alignment: .leading)
            .padding(.top, y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Make it yours: a preset for the bar's widgets and a theme for its look, with the bar between the title and them.
    @ViewBuilder private func choose(size: CGSize, bar: CGRect) -> some View {
        let layout = chooseLayout(size, bar: stageHeight(bar))
        VStack(spacing: 10) {
            title("Make it yours.")
            Text("Pick your widgets and a look. Your bar changes as you choose.")
                .font(.system(size: 16))
                .foregroundStyle(glass.ink.opacity(0.62))
        }
        .padding(.top, layout.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(motion.stepTransition(delay: 0))
        let presetRow = VStack(alignment: .leading, spacing: 12) {
            section("Widgets")
            presets(width: stageWidth(size))
        }
        let themeRow = VStack(alignment: .leading, spacing: 12) {
            section("Theme")
            themes(size: size)
        }
        .onGeometryChange(for: Double.self) { $0.size.height } action: { themesHeight = $0 }
        let end = size.height - dock - 108
        // On a short screen the presets and themes scroll, ending above the toolbar; under a bar that leaves no room,
        // they keep the presets' height over its bottom. The scroll bar takes the screen's edge, so it doesn't move them
        // off the stage.
        if layout.themes + themesHeight > end {
            let top = min(layout.presets, end - 98)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    presetRow
                    themeRow
                }
                .frame(width: stageWidth(size))
                .padding(.leading, (size.width - stageWidth(size)) / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: end - top)
            .padding(.top, top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(motion.stepTransition(delay: 0.06))
        } else {
            placed(presetRow, y: layout.presets, size: size)
                .transition(motion.stepTransition(delay: 0.06))
            placed(themeRow, y: layout.themes, size: size)
                .transition(motion.stepTransition(delay: 0.12))
        }
        if !session.suggestions.isEmpty {
            suggestionsPill
                .padding(.leading, 24)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(motion.stepTransition(delay: 0.18))
        }
    }

    private func presets(width: Double) -> some View {
        HStack(spacing: 12) {
            ForEach(SetupPreferences.Preset.allCases, id: \.self) { preset in
                let selected = session.preset == preset
                SetupTile(selected: selected) { session.toggle(preset) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(selected ? glass.inkOnSelected : glass.ink)
                            .frame(width: 38, height: 38)
                            .background(glass.ink.opacity(selected ? 0.92 : 0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title).font(.system(size: 15, weight: .semibold))
                            Text(preset.summary).font(.system(size: 12)).foregroundStyle(glass.ink.opacity(0.62)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 72)
                }
                .accessibilityLabel(preset.accessibilityLabel(widgetSets: session.widgetSets(preset)))
            }
        }
        .frame(width: width)
    }

    /// A tile for each theme, seven at a time, each with the top right of the screen in that theme with the chosen
    /// preset's widgets. More themes scroll sideways.
    private func themes(size: CGSize) -> some View {
        let width = (stageWidth(size) - 6 * 12) / 7
        return ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(session.themes, id: \.key) { themeTile($0, size: size, width: width) }
            }
            // Room for the chosen tile's shadow.
            .padding(40)
        }
        .padding(-40)
    }

    private func themeTile(_ choice: ThemeChoice, size: CGSize, width: Double) -> some View {
        let selected = choice.key == session.store.configurationStore.selectedThemeKey
        return SetupTile(selected: selected) { choose(choice) } label: {
            VStack(alignment: .leading, spacing: 0) {
                SetupThemeSample(preview: session.themePreviews[choice.key], appearance: tileAppearance(choice),
                                 widgets: session.preset.map(session.sampleWidgets), wallpaper: backdrop.images?.soft, size: size,
                                 width: width - 12)
                    .equatable()
                    .frame(width: width - 12, height: 54, alignment: .topTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .padding(6)
                HStack(spacing: 6) {
                    Text(choice.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if choice.key == session.currentThemeKey && !selected {
                        Text("Current").font(.system(size: 11)).foregroundStyle(glass.ink.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).opacity(selected ? 1 : 0)
                }
                .padding(EdgeInsets(top: 2, leading: 11, bottom: 10, trailing: 11))
            }
            .frame(width: width)
        }
        .accessibilityLabel("\(choice.title) theme")
    }

    private func choose(_ choice: ThemeChoice) {
        session.preferences.theme = choice.key == session.currentThemeKey ? .current
            : .package(id: choice.manifest.id, version: choice.isBundled ? nil : choice.manifest.version)
    }

    /// Allow what your bar needs: one row for each thing macOS must allow, each with its own button, then the preset's
    /// Store widgets, each with its review.
    @ViewBuilder private func allow(size: CGSize, bar: CGRect) -> some View {
        let layout = allowLayout(size, bar: bar.height)
        title("Allow what your bar needs.", size: 36)
            .padding(.top, layout.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(motion.stepTransition(delay: 0))
        let card = allowCard.onGeometryChange(for: Double.self) { $0.size.height } action: { allowCardHeight = $0 }
        let end = size.height - dock - 108
        let top = min(layout.card, end - 98)
        let room = end - top
        // On a short screen the card scrolls, ending above the toolbar; under a bar that leaves no room, it keeps a
        // row's height over the bar's bottom.
        Group {
            if allowCardHeight > room { ScrollView { card }.frame(height: room) } else { card }
        }
            .frame(width: min(760, size.width - 80))
            .padding(.top, top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(motion.stepTransition(delay: 0.06))
    }

    private var allowCard: some View {
        let calendars = session.needsCalendarAccess || session.preferences.widgetSets.contains(.meetings)
        let toAdd = session.storeWidgetsToAdd
        // A widget of your own with a Store widget's ID stays on the bar in its place, and the Store's isn't added.
        let widgets = session.preferences.widgetSets.compactMap { set -> (entry: PackageIndex.Entry, settings: [String: String])? in
            guard case let .store(id, _, _, settings) = set, let entry = session.storeEntries?.first(where: { $0.id == id }),
                  session.store.widgetPackageIDs[id] == id || session.store.configuration?.widgets.contains(where: { $0.id == id }) != true
            else { return nil }
            return (entry, settings)
        }
        let leftOut = session.preset.map(session.leftOut) ?? []
        return VStack(alignment: .leading, spacing: 0) {
            section("macOS asks once for each").padding(EdgeInsets(top: 14, leading: 18, bottom: 2, trailing: 18))
            automationRow
            divider
            accessibilityRow
            if calendars {
                divider
                calendarRow
            }
            if session.showsSpacesGuidance {
                divider
                shortcutsRow
            }
            if let managerGap {
                divider
                gapRow(managerGap)
            }
            if let preset = session.preset, !widgets.isEmpty || !leftOut.isEmpty {
                section("Store widgets in \(preset.title)").padding(EdgeInsets(top: 16, leading: 18, bottom: 2, trailing: 18))
                ForEach(widgets, id: \.entry.key) { widget in
                    if widget.entry.id != widgets.first?.entry.id { divider }
                    let added = !toAdd.contains { $0.entry.id == widget.entry.id }
                    row(widget.entry.symbol ?? "shippingbox", widget.entry.name,
                        widget.entry.description ?? "Runs commands from the Store. Add shows you what before it's on your bar.", done: added) {
                        if added {
                            allowedLabel("Added")
                        } else if session.downloading == widget.entry.key && session.review == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { Task { await session.review(widget) } } label: { Label("Add", systemImage: "plus") }
                                .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
                                .accessibilityLabel("Add \(widget.entry.name)")
                                .disabled(session.downloading != nil)
                        }
                    }
                }
                if !leftOut.isEmpty {
                    Text("The Store can't be reached, so \(preset.title) leaves out \(ListFormatter.localizedString(byJoining: leftOut)).")
                        .font(.system(size: 12.5)).foregroundStyle(glass.ink.opacity(0.62))
                        .padding(EdgeInsets(top: 8, leading: 18, bottom: 4, trailing: 18))
                }
            }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 8, leading: 18, bottom: 4, trailing: 18))
            }
        }
        .padding(.bottom, 8)
        .background(glass.backing, in: RoundedRectangle(cornerRadius: 18))
        .glass(RoundedRectangle(cornerRadius: 18))
        .task {
            session.store.workspaceStore.refreshDesktopShortcuts()
            // A menu bar that already hides needs no Automation, so the bar can take its place at once.
            if session.menuBarHides && session.placementChoice == nil { await session.place(.top) }
        }
        .task { await checkManagerGap() }
    }

    private var divider: some View {
        Rectangle().fill(glass.ink.opacity(0.1)).frame(height: 0.5).padding(.leading, 72)
    }

    private func row<Status: View>(_ symbol: String, _ title: String, _ detail: String, mac: String? = nil, done: Bool,
                                   @ViewBuilder status: () -> Status) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(done ? glass.allowed : glass.ink)
                .frame(width: 40, height: 40)
                .background(done ? Color(red: 0.204, green: 0.78, blue: 0.349).opacity(0.22) : glass.ink.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let mac { Text(mac).font(.system(size: 11.5, weight: .medium)).foregroundStyle(glass.ink.opacity(0.42)) }
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(glass.ink.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            status()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .animation(motion.movement(.snappy(duration: 0.3)), value: done)
    }

    private func allowedLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(glass.allowed)
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.system(size: 13))
        .foregroundStyle(glass.ink.opacity(0.62))
    }

    /// Automation lets StableBar hide the macOS menu bar. Refused, the bar sits below it instead.
    private var automationRow: some View {
        let phase = session.placementPhase
        let refused = if case .awaitingAccess = phase { true } else { false }
        let placed = phase == .placed(.top)
        return row("menubar.rectangle", "Take the menu bar's place",
                   refused ? "StableBar sits below the menu bar, since macOS didn't allow Automation. Change it later in Settings."
                       : "Hides the macOS menu bar. It comes back when you point at the top edge.",
                   mac: "Automation", done: placed) {
            switch phase {
            case .placed(.top):
                allowedLabel("Allowed")
            case .checkingAccess, .changingMenuBar:
                waiting("macOS is asking…")
            case .awaitingAccess:
                Button("Open Settings…") {
                    lowerTour()
                    MenuBarAutoHide.openAutomationSettings()
                }
                .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
                .accessibilityLabel("Open Automation Settings")
            // Below the menu bar once auto-hide was turned off, Allow offers the menu bar's place again.
            case .unchosen, .placed, .failed, .skipped:
                Button(SetupPermission.Action.allow.title) { Task { await session.place(.top) } }
                    .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
                    .accessibilityLabel("Allow Automation")
            }
        }
    }

    private var accessibilityRow: some View {
        let name = session.system.macOSVersion.accessibilityName
        return row("cursorarrow.click.2", "Open menus from the bar",
                   "The Apple menu, your app's menus and menu bar items open from the bar, and windows keep clear of it.",
                   mac: name, done: session.accessibilityAccess) {
            if session.accessibilityAccess {
                allowedLabel("Allowed")
            } else {
                permissionButton(.allow, for: .accessibility) {
                    lowerTour()
                    session.store.windowClearance.requestAccess()
                }
            }
        }
    }

    /// Calendars for Meetings, which can wait: Later saves Meetings turned off.
    private var calendarRow: some View {
        let allowed = session.calendarAccess == .fullAccess
        let refused = !allowed && session.calendarAccess != .notDetermined && !session.preferences.deferMeetings
        let later = session.needsCalendarSetup ? ", or choose Later to leave Meetings off" : ""
        return row("calendar", "See your next meeting",
                   refused ? "macOS didn't allow Calendars, so Finish setup waits. Allow it in Settings\(later)."
                       : "Meetings shows a countdown and Join before each call.",
                   mac: SetupPermission.calendars.title(on: session.system.macOSVersion), done: allowed) {
            if allowed {
                allowedLabel("Allowed")
            // A Meetings widget the bar already has stays on with Later, so Calendars is still needed.
            } else if session.preferences.deferMeetings && !session.needsCalendarAccess {
                HStack(spacing: 8) {
                    Text("Later").font(.system(size: 13)).foregroundStyle(glass.ink.opacity(0.62))
                    linkButton("Undo") { session.preferences.deferMeetings = false }
                }
            } else {
                HStack(spacing: 10) {
                    if session.needsCalendarSetup && !session.preferences.deferMeetings {
                        linkButton("Later") { session.preferences.deferMeetings = true }
                            .accessibilityLabel("Set up Meetings later")
                    }
                    if session.calendarAccess == .notDetermined {
                        permissionButton(.allow, for: .calendars) { Task { await session.requestCalendarAccess() } }
                    } else {
                        permissionButton(.openSettings, for: .calendars) {
                            lowerTour()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                }
            }
        }
    }

    /// The Switch to Desktop shortcuts Workspaces uses on macOS Spaces. Setup finishes without them.
    private var shortcutsRow: some View {
        let status = session.store.workspaceStore.desktopShortcutStatus
        return row("keyboard", "Switch desktops from the bar",
                   "Turn on Switch to Desktop for each desktop in Keyboard Shortcuts → Mission Control.",
                   mac: "Optional", done: status.allEnabled) {
            if status.allEnabled {
                allowedLabel("Ready")
            } else {
                Button(DesktopShortcuts.actionTitle) {
                    lowerTour()
                    do { try DesktopShortcuts.openSettings() }
                    catch { session.error = errorMessage(error) }
                }
                .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
            }
        }
        .help(status.detail)
        .accessibilityHint(status.detail)
    }

    /// The gap a window manager needs to keep windows clear of the bar, as Settings → General shows it.
    private func gapRow(_ gap: ManagerGap) -> some View {
        row("macwindow", "Keep windows clear of the bar", gap.setting, mac: gap.manager.title, done: false) {
            HStack(spacing: 8) {
                if let file = gap.configuration {
                    Button("Open \(file.lastPathComponent)") {
                        lowerTour()
                        openInTextEditor(file)
                    }
                    .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
                }
                Button("Check Again") { Task { await checkManagerGap() } }
                    .buttonStyle(GlassButtonStyle(selected: false, size: .compact))
            }
        }
    }

    private func checkManagerGap() async {
        guard let configuration = session.store.configuration else { return }
        managerGap = await session.store.windowClearance.checkManagerGap(configuration)
    }

    private func permissionButton(_ kind: SetupPermission.Action, for permission: SetupPermission, action: @escaping () -> Void) -> some View {
        let label = kind.accessibilityLabel(for: permission, on: session.system.macOSVersion)
        return Button(kind.title, action: action)
            .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
            .accessibilityLabel(label)
            .accessibilityInputLabels([Text(kind.title), Text(label)])
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .linkPointer()
            .font(.system(size: 12))
            .underline()
            .foregroundStyle(glass.ink.opacity(0.62))
    }

    /// Store packages for tools found on this Mac. They run commands, so adding one opens its review first.
    private var suggestionsPill: some View {
        Button { showsSuggestions.toggle() } label: {
            GlassPill {
                HStack(spacing: 7) {
                    Text("Found on your Mac")
                    Text("\(session.suggestions.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(glass.ink.opacity(0.22), in: Capsule())
                }
            }
            .background(glass.backing, in: Capsule())
            .overlay(Capsule(style: .circular).pixelBorder(Self.gold.opacity(0.55), width: 2).padding(-2))
            .shadow(color: Self.gold.opacity(0.35), radius: 7)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) { suggestionList }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Store widgets for tools on this Mac. Nothing downloads until you add one.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))
            ForEach(session.suggestions, id: \.key) { entry in
                let added = session.preferences.packages.contains { $0.id == entry.id }
                HStack(spacing: 10) {
                    Image(systemName: entry.symbol ?? "shippingbox")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .background(glass.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.system(size: 13.5, weight: .semibold))
                        if let description = entry.description {
                            Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if session.downloading == entry.key {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await session.pick(entry) } } label: {
                            Label(added ? "Added" : "Add", systemImage: added ? "checkmark" : "plus")
                        }
                        .buttonStyle(GlassButtonStyle(selected: !added, highlighted: added, size: .compact))
                        .accessibilityLabel(added ? "Remove \(entry.name)" : "Add \(entry.name)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .padding(8)
        .frame(width: 400)
        .disabled(session.downloading != nil)
    }

    /// The review Add here shows, for a suggestion picked under Found on your Mac or a preset's Store widget.
    private func suggestionReview(_ review: (inspection: WidgetPackageInspection, sourceID: String, settings: [String: ConfigurationValue]?)) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 10) {
                PackagesView(store: session.store, reviewing: review.inspection, reviewingSourceID: review.sourceID,
                             reviewingSettings: review.settings,
                             onEnable: { session.add($0, settings: $1) }, onAdded: { session.endReview() },
                             onWorkingChanged: { reviewIsWorking = $0 })
                    .id(review.inspection.manifest.versionKey)
                Button("Back") { session.endReview() }
                    .buttonStyle(GlassButtonStyle(selected: false, highlighted: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(reviewIsWorking)
            }
            .padding(14)
            .frame(width: 540, height: 540)
            .background(glass.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).pixelBorder(glass.edge, width: 0.5))
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            Image(nsImage: StableBarIcon.image)
                .resizable()
                .frame(width: 84, height: 84)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(SettingsPalette.success, in: Circle())
                        .overlay(Circle().pixelBorder(glass.panel, width: 3))
                        .offset(x: 6, y: 6)
                }
                .accessibilityHidden(true)
                .padding(.bottom, 14)
            Text("You're all set.").font(.system(size: 28, weight: .semibold)).padding(.bottom, 6)
            Text("Click a widget to open it. Right-click the bar to edit it in place, try themes or open Settings.")
                .font(.system(size: 14))
                .foregroundStyle(glass.ink.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            VStack(spacing: 10) {
                if session.preferences.widgetSets.contains(.meetings) && session.preferences.deferMeetings {
                    Label("Meetings stays off. Turn it on in Settings → Bar when you're ready to allow Calendar access.", systemImage: "calendar")
                        .font(.system(size: 12.5)).foregroundStyle(glass.ink.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupLoginCard(session: session, reveal: lower)
                if session.finished && session.loginStatus == .requiresApproval {
                    Text("Open at login still needs your approval in macOS.").font(.system(size: 12.5))
                    Button("Allow StableBar in Login Items…") {
                        lowerTour()
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(GlassButtonStyle(selected: false, highlighted: true, size: .compact))
                }
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 16)
            HStack(spacing: 8) {
                if let editBar {
                    Button("Edit Bar in Place") { finish(then: editBar) }
                        .buttonStyle(GlassButtonStyle(selected: false, highlighted: true))
                }
                Button { finish() } label: {
                    HStack(spacing: 7) {
                        Text("Done")
                        Image(systemName: "checkmark")
                    }
                }
                .buttonStyle(GlassButtonStyle(selected: true))
                .keyboardShortcut(.defaultAction)
            }
            .disabled(session.applicationMove.isBusy || session.placementSettling)
        }
        .padding(EdgeInsets(top: 30, leading: 30, bottom: 22, trailing: 30))
        .frame(width: 480)
        // A shadow on the whole card makes offscreen drawings blur all of its content, for seconds per drawing.
        .background {
            RoundedRectangle(cornerRadius: 26).fill(glass.panel).shadow(color: glass.shadow.opacity(0.45), radius: 40, y: 15)
        }
        .overlay(RoundedRectangle(cornerRadius: 26).pixelBorder(glass.edge, width: 0.5))
    }

    /// Saves the bar and closes setup, or keeps it open to show that Open at login waits for approval in macOS. Once the
    /// card shows that, Done closes setup; once it shows that Open at login failed, Done tries it again and closes either
    /// way, since the bar is saved.
    private func finish(then next: (() -> Void)? = nil) {
        let loginFailed = session.finished && session.error != nil
        let approvalShown = session.finished && session.loginStatus == .requiresApproval
        if !session.finished || session.error != nil {
            session.finish()
            // A permission taken back since Finish setup sends the tour back to its row.
            if !session.missingPermissions.isEmpty { withAnimation(motion.stageAnimation) { session.step = .allow } }
        }
        guard session.finished, session.error == nil || loginFailed, session.loginStatus != .requiresApproval || approvalShown else { return }
        close()
        next?()
    }

    /// Continue, or Back and Finish setup, which waits for what the bar needs from macOS.
    private var toolbar: some View {
        let allowing = session.step == .allow
        return HStack(spacing: 2) {
            if allowing {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 36)
                }
                .buttonStyle(GlassButtonStyle(selected: false, round: true))
                .accessibilityLabel("Back")
            }
            Button {
                if allowing { land() } else { withAnimation(motion.stageAnimation) { session.step = .allow } }
            } label: {
                HStack(spacing: 7) {
                    Text(allowing ? "Finish setup" : "Continue")
                    Image(systemName: allowing ? "checkmark" : "arrow.right")
                }
            }
            .buttonStyle(GlassButtonStyle(selected: true))
            .keyboardShortcut(.defaultAction)
            .disabled(allowing && !(arrived && session.readyToLand && session.missingPermissions.isEmpty))
        }
        .padding(4)
        .background(glass.backing, in: Capsule())
        .glass(Capsule(style: .circular))
        .fixedSize()
    }

    /// Finish setup: below the menu bar, the bar itself takes over from its copy, and the last card drops in.
    private func land() {
        reveal()
        landed = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.7, bounce: 0.22)) { session.step = .done }
    }

    /// The bar's copy takes the bar's place again, then flies back to the stage, with the tour over the menu bar.
    /// Keeps the real bar from drawing under the tour until its copy has flown there.
    private func coverBar() {
        if session.store.barEditing.setupCoversDisplay != display.id { session.store.barEditing.setupCoversDisplay = display.id }
    }

    /// Lets System Settings or a prompt come in front without the real bar showing at the top before its copy flies.
    private func lowerTour() {
        lowered = true
        if !flown { coverBar() }
        lower()
    }

    private func back() {
        cover()
        coverBar()
        landed = false
        arrived = false
        backs += 1
        Task {
            withAnimation(motion.stageAnimation) {
                flown = false
                session.step = .choose
            }
        }
    }

    /// Whether the corner button saves and closes as Done does: on the last card, unless saving the bar failed there.
    private var cornerSaves: Bool { session.step == .done && (session.finished || session.error == nil) }

    private func skip() {
        if cornerSaves { finish() } else if session.finished || !session.hasChanges { close() } else { confirmingSkip = true }
    }

    /// Asks before Skip setup, or Esc, throws away the choices made so far.
    private var skipConfirmation: some View {
        ZStack {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { confirmingSkip = false }
            VStack(spacing: 6) {
                Text("Skip setup?").font(.system(size: 20, weight: .semibold))
                Text("""
                    Your bar goes back to how it was\(session.changedMenuBar ? ", and so does the macOS menu bar" : ""), and nothing is saved. \
                    Open setup again with Getting Started… in the menu-bar icon's menu.
                    """)
                    .foregroundStyle(glass.ink.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                HStack(spacing: 8) {
                    Button("Skip Setup") {
                        confirmingSkip = false
                        close()
                    }
                    .buttonStyle(GlassButtonStyle(selected: false, highlighted: true))
                    Button("Keep Setting Up") { confirmingSkip = false }
                        .buttonStyle(GlassButtonStyle(selected: true))
                        .keyboardShortcut(.defaultAction)
                }
                // Esc keeps setting up while the question shows.
                Button("") { confirmingSkip = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .padding(22)
            .frame(width: 360)
            .background(glass.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).pixelBorder(glass.edge, width: 0.5))
        }
    }
}

/// Shantell Sans from the app's resources, or the system font outside the app bundle, as when tests draw setup.
func shantellSans(_ file: String, size: Double) -> CTFont {
    guard let url = Bundle.main.url(forResource: file, withExtension: "woff2"),
          let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else {
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

/// A theme tile's picture: the top right of the screen in the theme, with the chosen preset's widgets. Choosing a theme
/// changes only which tile is selected, so the pictures aren't drawn again.
private struct SetupThemeSample: View, Equatable {
    let preview: ThemePreview?
    let appearance: BarAppearance
    let widgets: [[String: ConfigurationValue]]?
    let wallpaper: CGImage?
    let size: CGSize
    let width: Double
    @Environment(\.fixedDate) private var fixedDate

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.preview == nil) == (rhs.preview == nil) && lhs.appearance == rhs.appearance && lhs.widgets == rhs.widgets
            && lhs.wallpaper === rhs.wallpaper && lhs.size == rhs.size && lhs.width == rhs.width
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let wallpaper {
                Image(decorative: wallpaper, scale: 1).resizable().frame(width: size.width, height: size.height)
            }
            if let preview {
                let look = preview.configuration(for: appearance)
                // A widget whose theme gives a token it can't use, such as a number for a color, stays off the tile.
                let right = (widgets.map { widgets in
                    widgets.compactMap { try? substituteConfigurationReferences(.object($0), prefix: "@token.", values: preview.tokens(for: appearance))
                        .decoded(WidgetConfiguration.self) }
                } ?? ThemeSampleBar.sampleWidgets).filter { $0.position == .right }
                TimelineView(.everyMinute) { context in
                    // The right widgets that fit the tile whole, leaving out the leftmost first, or the bar without them.
                    ViewThatFits(in: .horizontal) {
                        ForEach(right.indices, id: \.self) { first in
                            ThemeSampleBar(look: look, widgets: Array(right[first...]), date: fixedDate ?? context.date)
                        }
                        ThemeSampleBar(look: look, widgets: [], date: fixedDate ?? context.date)
                    }
                }
                .frame(width: width / 0.7, height: 76)
                .offset(y: -(76 - look.bar.height) / 2)
            }
        }
        .environment(\.colorScheme, appearance.colorScheme)
        .scaleEffect(0.7, anchor: .topTrailing)
    }
}

/// Setup's own colors besides its glass.
extension GlassPalette {
    /// Over the wallpaper behind the tour: a dim, a little blue so a light wallpaper doesn't turn grey, or a light veil.
    var veil: Color { dark ? Color(red: 0.05, green: 0.04, blue: 0.16).opacity(0.4) : Color(red: 0.98, green: 0.97, blue: 1).opacity(0.45) }
    var tagline: Color { dark ? Color(red: 0.949, green: 0.933, blue: 1) : ink }
    var allowed: Color { dark ? Color(red: 0.557, green: 0.941, blue: 0.659) : Color(red: 0.11, green: 0.52, blue: 0.25) }
    /// Lighter over the light veil, where a dark shadow would smudge it.
    var shadow: Color { .black.opacity(dark ? 1 : 0.4) }
    /// A card in front of the tour.
    var panel: Color { dark ? Color(red: 0.11, green: 0.11, blue: 0.125) : Color(red: 0.965, green: 0.96, blue: 0.975) }
    /// The demo's blueprint.
    var blueprint: Color { dark ? Color(red: 0.62, green: 0.8, blue: 1) : Color(red: 0.12, green: 0.36, blue: 0.72) }
}

struct SetupTile<Label: View>: View {
    let selected: Bool
    var focusChanged: (Bool) -> Void = { _ in }
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false
    @State private var clearingFocus = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var motion: SetupMotion { SetupMotion(reduceMotion: reduceMotion) }

    var body: some View {
        let glass = GlassPalette(colorScheme)
        return Button {
            clearingFocus = true
            focused = false
            action()
        } label: {
            label
                .background(glass.fill(selected ? 0.16 : hovering ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).pixelBorder(selected ? glass.ink : glass.edge, width: selected ? 2.5 : 0.5))
                .shadow(color: glass.shadow.opacity(selected ? 0.3 : 0), radius: 15, y: 10)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 16))
        // Unrestricted focus includes Tab without macOS's Keyboard navigation setting, from macOS 14 on.
        .focusable(isEnabled)
        .focused($focused)
        .focusEffectDisabled(false)
        .task { focused = false }
        .onChange(of: focused) {
            // AppKit can assign mouse focus after the button's action; dismiss that ring too.
            if clearingFocus {
                focused = false
                clearingFocus = false
            }
            focusChanged(focused)
        }
        .onKeyPress(keys: [.space], phases: .down) { _ in
            guard isEnabled else { return .ignored }
            action()
            return .handled
        }
        .onHover { hovering = $0 }
        .linkPointer()
        .animation(motion.movement(.snappy(duration: 0.2)), value: hovering)
        .animation(motion.movement(.snappy(duration: 0.25)), value: selected)
        .accessibilityAction { action() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
