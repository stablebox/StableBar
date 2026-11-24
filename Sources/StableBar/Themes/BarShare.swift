import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

@MainActor let barShare = BarShareWindow()

@MainActor
final class BarShareWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var store: BarStore?

    /// Opens Share My Bar on `screen`'s bar, or shows that bar in it when it's already open.
    func show(store: BarStore, screen: NSScreen) {
        self.store = store
        store.barEditing.end()
        let display = BarDisplay(screen: screen)
        let share = BarShare(store: store, display: display, screen: screen.frame.size, menuBar: screen.menuBarHeight,
                             wallpaper: NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:)),
                             menuBarScheme: MenuBarAppearance.shared.schemes[display.id], defaults: .standard)
        let host = NSHostingView(rootView: BarShareView(share: share) { [weak self] in self?.window?.performClose(nil) })
        if window == nil {
            // A title bar with nothing in it keeps the panel resizable and closable with ⌘W, behind a borderless look.
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                                 styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                                 backing: .buffered, defer: false)
            window.title = "Share My Bar"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.minSize = NSSize(width: 520, height: 360)
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window!.contentView = host
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Settings keeps StableBar in the Dock while it's open.
        if store?.widgetScripts.inspectorOpen != true { NSApplication.shared.setActivationPolicy(.accessory) }
    }
}

/// The screen Share My Bar draws the bar on: the one it opened on, or a MacBook's at its default size.
enum BarShareScreen: String, CaseIterable, Identifiable, Decodable {
    case this, air13, pro14, pro16

    var id: Self { self }

    var title: String {
        switch self {
        case .this: "This screen"
        case .air13: "13″ MacBook Air"
        case .pro14: "14″ MacBook Pro"
        case .pro16: "16″ MacBook Pro"
        }
    }

    /// The MacBook's screen, its notch's width and its menu bar's height with the notch, in points.
    var macBook: (size: CGSize, notch: CGFloat, menuBar: Double)? {
        switch self {
        case .this: nil
        case .air13: (CGSize(width: 1470, height: 956), 186, 33)
        case .pro14: (CGSize(width: 1512, height: 982), 211, 37)
        case .pro16: (CGSize(width: 1728, height: 1117), 211, 37)
        }
    }
}

enum BarSharePreset: String, CaseIterable, Identifiable, Decodable {
    case bar, landscape, square, portrait

    var id: Self { self }

    /// The name in the toolbar.
    var label: String {
        switch self {
        case .bar: "Bar"
        case .landscape: "16:9"
        case .square: "1:1"
        case .portrait: "4:5"
        }
    }

    /// The name VoiceOver reads.
    var title: String {
        switch self {
        case .bar: "Bar only"
        case .landscape: "16:9"
        case .square: "Square"
        case .portrait: "4:5"
        }
    }

    /// Twice the usual sizes for social media, so the bar's small text stays sharp. The bar alone is twice the
    /// screen's width.
    var pixels: NSSize? {
        switch self {
        case .bar: nil
        case .landscape: NSSize(width: 3200, height: 1800)
        case .square: NSSize(width: 2160, height: 2160)
        case .portrait: NSSize(width: 2160, height: 2700)
        }
    }

    /// The tooltip: the shape and its size.
    var help: String {
        pixels.map { "\(title), \(Int($0.width)) × \(Int($0.height)) pixels" } ?? "The bar alone, on a strip of wallpaper"
    }
}

/// A social network Share My Bar posts to, through its compose page, which takes the caption and the bar link but not
/// the image.
enum BarShareNetwork: CaseIterable, Identifiable {
    case x, bluesky, threads, reddit

    var id: Self { self }

    var name: String {
        switch self {
        case .x: "X"
        case .bluesky: "Bluesky"
        case .threads: "Threads"
        case .reddit: "Reddit"
        }
    }

    /// The network's logo, or nil where the app's resources aren't bundled, as in tests.
    var logo: NSImage? {
        Bundle.main.url(forResource: "Share\(name)", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
    }

    /// The compose page, filled in with `caption` and `link`.
    func compose(_ caption: String, link: URL?) -> URL {
        let link = link?.absoluteString
        let (page, fields): (String, [(String, String?)]) = switch self {
        case .x: ("https://x.com/intent/tweet", [("text", caption), ("url", link)])
        // Bluesky's takes only text, and links the address in it.
        case .bluesky: ("https://bsky.app/intent/compose", [("text", [caption, link].compactMap { $0 }.joined(separator: " "))])
        case .threads: ("https://www.threads.com/intent/post", [("text", caption), ("url", link)])
        case .reddit: ("https://www.reddit.com/submit", [("title", caption), ("url", link)])
        }
        // In a value, `&` and `=` would end it, and `+` would read as a space.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
        let query = fields.compactMap { name, value in value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)" } }
        return URL(string: "\(page)?\(query.joined(separator: "&"))")!
    }
}

/// What Share My Bar draws: the screen, with or without the MacBook's notch, and the image's shape.
struct BarShareFormat: Equatable {
    var screen = BarShareScreen.this
    var notch = true
    var preset = BarSharePreset.bar
}

/// The bar of one screen as it is now, at its place on the desktop over the screen's wallpaper, drawn as an image of
/// the chosen format, with StableBar's badge in a corner unless it's turned off.
@MainActor @Observable
final class BarShare {
    static let badgeKey = "shareMyBarBadge"
    static let captionKey = "shareMyBarCaption"

    /// The desktop as drawn, without the badge, `size` points large; `bottom` for a bar at the bottom.
    struct Drawing {
        let image: CGImage
        let size: CGSize
        let bottom: Bool
    }

    var format = BarShareFormat()
    /// Whether the image carries StableBar's logo and website, remembered for the next share.
    var badge: Bool {
        didSet {
            defaults?.set(badge, forKey: Self.badgeKey)
            compose()
        }
    }
    /// What a post says before the bar link, remembered for the next share.
    var caption: String {
        didSet { defaults?.set(caption, forKey: Self.captionKey) }
    }
    private(set) var drawn: Drawing?
    /// `drawn`'s image with the badge when it's on.
    private(set) var image: CGImage?
    /// Where the badge goes in the image, in points from its top left, whether it's on or not.
    private(set) var badgeFrame: CGRect?
    /// The image blurred, behind the window. Blurred here rather than by SwiftUI, whose blur offscreen drawings leave out.
    private(set) var backdrop: NSImage?
    @ObservationIgnored private let store: BarStore
    @ObservationIgnored private let display: BarDisplay
    @ObservationIgnored private let screen: CGSize
    @ObservationIgnored private let menuBar: Double
    /// Nil when the wallpaper has no still image, as a dynamic or aerial one can.
    @ObservationIgnored private let wallpaper: NSImage?
    /// The look of the display's menu bar, which a bar that follows the wallpaper takes. Nil in scenes.
    @ObservationIgnored private let menuBarScheme: ColorScheme?
    /// Nil where the badge's choice isn't kept, as in scenes.
    @ObservationIgnored private let defaults: UserDefaults?
    /// Whether `format`'s screen has a notch, which the image can leave out.
    var hasNotch: Bool { format.screen.macBook != nil || display.notch != nil }
    /// The bar link and what it carries, or why the bar can't be shared as one.
    private(set) var link: Result<BarLink.Sharing, Error>?

    init(store: BarStore, display: BarDisplay, screen: CGSize, menuBar: Double, wallpaper: NSImage?, menuBarScheme: ColorScheme? = nil,
         defaults: UserDefaults? = nil) {
        self.store = store
        self.display = display
        self.screen = screen
        self.menuBar = menuBar
        self.wallpaper = wallpaper
        self.menuBarScheme = menuBarScheme
        self.defaults = defaults
        badge = defaults?.object(forKey: Self.badgeKey) as? Bool ?? true
        caption = defaults?.string(forKey: Self.captionKey) ?? "My macOS bar, made with StableBar. Try it on yours:"
    }

    /// The bar link, unless the bar can't be shared as one.
    var linkURL: URL? { (try? link?.get())?.link }

    /// The caption and the bar link, as Copy Caption and the macOS share menu give them.
    var post: String { [caption, linkURL?.absoluteString].compactMap { $0 }.joined(separator: " ") }

    /// `image` as PNG, at twice its size in points per inch, as Copy, Save and Share give it.
    var png: Data? {
        guard let image, let drawn else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = drawn.size
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws the top of the desktop, or its bottom for a bar at the bottom, at the width of `format`'s screen and in
    /// its shape. A MacBook's screen shows the bar as it lays out there, around the notch when it has one. The bar
    /// alone gets 120 points of wallpaper beyond it. The wallpaper fills the screen, or the image when that's taller.
    /// Clocks show `fixedDate`, or the time now, and a bar without its own appearance takes `colorScheme`.
    func draw(fixedDate: Date?, colorScheme: ColorScheme) async {
        image = nil
        var display = display
        var screen = screen
        var menuBar = menuBar
        if let macBook = format.screen.macBook {
            display = BarDisplay(id: display.id, isBuiltIn: true, isMain: display.isMain,
                                 notch: (macBook.size.width - macBook.notch) / 2...(macBook.size.width + macBook.notch) / 2)
            display.notchHeight = macBook.menuBar
            screen = macBook.size
            menuBar = format.notch ? macBook.menuBar : 24
        }
        if !format.notch {
            display = BarDisplay(id: display.id, isBuiltIn: display.isBuiltIn, isMain: display.isMain, notch: nil, isPortrait: display.isPortrait)
        }
        let configuration = store.configuration?.onScreen(ScreenKind(display))
        let bottom = configuration?.bar.position == .bottom
        let edge = (bottom ? configuration?.bar.offset : configuration?.bar.top(menuBar: menuBar)) ?? 0
        let strip = edge + (configuration?.barGeometry(for: display).panelHeight ?? 0) + 120
        let pixels = format.preset.pixels ?? NSSize(width: screen.width * 2, height: strip * 2)
        let size = NSSize(width: screen.width, height: screen.width * pixels.height / pixels.width)
        let dark = (configuration?.bar.appearance?.colorScheme ?? colorScheme) == .dark
        let desktop = BarView(store: store, display: display, preview: true)
            .padding(bottom ? .bottom : .top, edge)
            .frame(width: size.width, height: max(screen.height, size.height))
            .overlay(alignment: .top) {
                if let notch = display.notch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                        .fill(.black)
                        .frame(width: notch.upperBound - notch.lowerBound, height: display.notchHeight)
                }
            }
            .background {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                } else {
                    OffscreenSnapshot.backdrop(dark: dark)
                }
            }
            .frame(width: size.width, height: size.height, alignment: bottom ? .bottom : .top)
            .clipped()
            .environment(\.fixedDate, fixedDate)
            .environment(\.menuBarScheme, menuBarScheme)
        let png = try? await OffscreenSnapshot.png(desktop, size: size, pixels: pixels, dark: dark, settle: .after(.seconds(1)),
                                                   name: "Share My Bar")
        guard !Task.isCancelled else { return }
        drawn = png.flatMap { NSBitmapImageRep(data: $0)?.cgImage }.map { Drawing(image: $0, size: size, bottom: bottom) }
        backdrop = drawn.flatMap { Self.blurred($0.image) }
        compose()
        // Made right after the drawing, on the main actor, so the link carries the bar the image shows.
        link = Result { try BarLink.sharing(store, on: display) }
    }

    private func compose() {
        guard let drawn else {
            image = nil
            badgeFrame = nil
            return
        }
        let scale = CGFloat(drawn.image.width) / drawn.size.width
        let art = BarShareBadge.render(scale: scale)
        badgeFrame = art.map {
            Self.badgeFrame(CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale), in: drawn.size, bottom: drawn.bottom)
        }
        if badge, let art, let badgeFrame {
            image = Self.composite(drawn.image, badge: art, at: badgeFrame, scale: scale) ?? drawn.image
        } else {
            image = drawn.image
        }
    }

    /// The frame of a badge `badge` large in an image `size` large: in its bottom-right corner, or its top-right one
    /// for a bar at the bottom, so it sits on the wallpaper beyond the bar.
    nonisolated static func badgeFrame(_ badge: CGSize, in size: CGSize, bottom: Bool) -> CGRect {
        CGRect(x: size.width - badge.width - BarShareBadge.inset,
               y: bottom ? BarShareBadge.inset : size.height - badge.height - BarShareBadge.inset,
               width: badge.width, height: badge.height)
    }

    /// `image` with `badge` over it at `frame`, in points from its top left, `scale` pixels to a point.
    nonisolated static func composite(_ image: CGImage, badge: CGImage, at frame: CGRect, scale: CGFloat) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        // Core Graphics counts from the bottom left.
        context.draw(badge, in: CGRect(x: frame.minX * scale, y: bounds.height - frame.maxY * scale,
                                       width: frame.width * scale, height: frame.height * scale))
        return context.makeImage()
    }

    /// Blurred at a quarter of the size, which looks the same behind the window for a sixteenth of the work.
    private static func blurred(_ image: CGImage) -> NSImage? {
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: small.extent)
        return CIContext().createCGImage(blurred, from: small.extent).map { NSImage(cgImage: $0, size: small.extent.size) }
    }
}

/// StableBar's logo, name and website, as Share My Bar draws them in a corner of the image.
struct BarShareBadge: View {
    /// From the image's edges to the badge, whose own `padding` leaves room for its shadow.
    nonisolated static let inset: CGFloat = 12
    nonisolated static let padding: CGFloat = 12
    private static let wordmark = Font(shantellSans("shantell-sans-display", size: 22))

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: StableBarIcon.image).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "StableBar").font(Self.wordmark)
                Text(verbatim: "stablebar.app").font(.system(size: 13, weight: .medium)).opacity(0.88)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 5, y: 1)
        .padding(Self.padding)
    }

    /// The badge, `scale` pixels to a point.
    static func render(scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: BarShareBadge())
        renderer.scale = scale
        return renderer.cgImage
    }
}

struct BarShareView: View {
    @Bindable var share: BarShare
    @State var showsLink = false
    @State var showsDetails = false
    @State var showsPost = false
    var close: () -> Void = {}
    @State private var detailsHeight: CGFloat = 0
    @State private var copied = false
    /// What the Share card's last action did, such as copying the image.
    @State private var note: String?
    @State private var overImage = false
    @Environment(\.fixedDate) private var fixedDate
    @Environment(\.colorScheme) private var colorScheme
    @State private var anchor = NSView()

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                screenMenu
                Spacer(minLength: 12)
                closeButton
            }
            stage
            toolbar
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            if showsLink { linkCard.padding(.top, 56).padding(.bottom, 70) }
            if showsPost { postCard.padding(.top, 56).padding(.bottom, 70) }
        }
        .background { backdrop.overlay(WindowDragArea()) }
        .ignoresSafeArea()
        // The window stays dark over any image, while `colorScheme` still gives a bar without its own appearance its look.
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .frame(minWidth: 520, minHeight: 360)
        .task(id: share.format) { await share.draw(fixedDate: fixedDate, colorScheme: colorScheme) }
        .onChange(of: showsLink) { copied = false }
        .onChange(of: showsPost) { note = nil }
        .onChange(of: share.format) {
            copied = false
            note = nil
        }
    }

    private var backdrop: some View {
        Color(white: 0.14)
            .overlay {
                if let backdrop = share.backdrop { Image(nsImage: backdrop).resizable().scaledToFill() }
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            .clipped()
    }

    private var screenMenu: some View {
        Menu {
            Picker("Screen", selection: $share.format.screen) {
                ForEach(BarShareScreen.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            if share.hasNotch { Toggle("Notch", isOn: $share.format.notch) }
            Toggle("StableBar Badge", isOn: $share.badge)
        } label: {
            GlassPill { Text(share.format.screen.title) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The screen, its notch and the StableBar badge")
    }

    private var closeButton: some View {
        GlassCloseButton(title: "Close") {
            if showsLink {
                showsLink = false
            } else if showsPost {
                showsPost = false
            } else {
                close()
            }
        }
    }

    /// The image over a blur of itself, with the badge's spot.
    private var stage: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = share.image, let drawn = share.drawn {
                    let fit = Self.fit(drawn.size, in: proxy.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                        .overlay(alignment: .topLeading) {
                            if let frame = share.badgeFrame { badgeSpot(frame, scale: fit.width / drawn.size.width) }
                        }
                        .onHover { overImage = $0 }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// The badge's corner while the pointer is over the image: the badge with a button that removes it, or a button
    /// that brings it back.
    @ViewBuilder private func badgeSpot(_ frame: CGRect, scale: CGFloat) -> some View {
        let shown = frame.insetBy(dx: BarShareBadge.padding, dy: BarShareBadge.padding)
        let rect = CGRect(x: shown.minX * scale, y: shown.minY * scale, width: shown.width * scale, height: shown.height * scale)
        if overImage {
            Group {
                if share.badge {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .padding(-4)
                        .overlay(alignment: .topLeading) {
                            Button { share.badge = false } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .heavy))
                                    .frame(width: 18, height: 18)
                                    .background(Color(white: 0.17), in: Circle())
                                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: -13, y: -13)
                            .help("Remove the StableBar badge")
                            .accessibilityLabel("Remove StableBar Badge")
                        }
                } else {
                    Button { share.badge = true } label: {
                        Label("Badge", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Add the StableBar badge")
                    .frame(width: rect.width, height: rect.height, alignment: .trailing)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(BarSharePreset.allCases) { preset in
                Button(preset.label) { share.format.preset = preset }
                    .buttonStyle(GlassButtonStyle(selected: share.format.preset == preset))
                    .help(preset.help)
                    .accessibilityLabel(preset.title)
                    .accessibilityAddTraits(share.format.preset == preset ? .isSelected : [])
            }
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 20).padding(.horizontal, 6)
            tool("doc.on.doc", "Copy Image", action: copy).disabled(share.image == nil)
            tool("square.and.arrow.down", "Save Image…", action: save).disabled(share.image == nil)
            tool("link", "Bar Link", selected: showsLink) {
                showsLink.toggle()
                showsPost = false
            }
            .disabled(share.link == nil)
            Button {
                showsPost.toggle()
                showsLink = false
            } label: {
                Label("Share", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
            .buttonStyle(GlassButtonStyle(selected: true))
            .keyboardShortcut(.defaultAction)
            .help("Post the image and the bar link")
            .disabled(share.image == nil)
            .padding(.leading, 4)
        }
        .padding(4)
        .glass(Capsule(style: .circular))
        .fixedSize()
    }

    private func tool(_ symbol: String, _ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 36)
        }
        .buttonStyle(GlassButtonStyle(selected: false, highlighted: selected, round: true))
        .help(title)
        .accessibilityLabel(title)
    }

    /// The bar link, what it shares and what stays on this Mac, above the toolbar.
    @ViewBuilder private var linkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch share.link {
            case let .success(sharing)?:
                HStack {
                    Label("Bar link", systemImage: "link").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 12)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sharing.link.absoluteString, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(GlassButtonStyle(selected: true, size: .compact))
                    // While the image redraws, the link is still the last screen's.
                    .disabled(share.image == nil)
                }
                Text("Anyone with StableBar can try your bar and keep the widgets they like. Scripts and private settings stay on your Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                details(sharing)
            case let .failure(error)?:
                Text(errorMessage(error)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
            case nil: EmptyView()
            }
        }
        .modifier(ShareCard())
    }

    /// The caption and the bar link, the networks that post them, and the macOS share menu, above the toolbar.
    private var postCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                TextField("Caption", text: $share.caption, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(2...4)
                Group {
                    switch share.link {
                    case let .success(sharing)?: Text(sharing.link.absoluteString).lineLimit(1).truncationMode(.middle)
                    case let .failure(error)?: Text(errorMessage(error))
                    case nil: EmptyView()
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
            HStack(spacing: 6) {
                ForEach(BarShareNetwork.allCases) { network in
                    Button { post(to: network) } label: {
                        if let logo = network.logo {
                            Image(nsImage: logo).renderingMode(.template).resizable().frame(width: 16, height: 16).frame(width: 40)
                        } else {
                            Text(network.name).padding(.horizontal, 12)
                        }
                    }
                    .buttonStyle(GlassButtonStyle(selected: false, round: true))
                    .help("Post on \(network.name)")
                    .accessibilityLabel("Post on \(network.name)")
                }
            }
            if let note {
                Label(note, systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
            }
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 6) {
                Button("Copy Image") {
                    copy()
                    note = "Image copied"
                }
                Button("Copy Caption") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(share.post, forType: .string)
                    note = "Caption and bar link copied"
                }
                Spacer(minLength: 0)
                Button("More…", action: more).background(MenuAnchor(view: anchor))
            }
            .buttonStyle(GlassButtonStyle(selected: false, size: .compact))
        }
        // While the image redraws, the link is still the last screen's.
        .disabled(share.image == nil)
        .modifier(ShareCard())
    }

    private func details(_ sharing: BarLink.Sharing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation { showsDetails.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.6)
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text("What it shares").font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SharedRow(symbol: "paintpalette", name: "Look", detail: sharing.look)
                        ForEach(Array(sharing.widgets.filter { $0.leftOut == nil }.enumerated()), id: \.offset) { _, widget in
                            SharedRow(symbol: widget.symbol, name: widget.name, store: widget.store,
                                      detail: widget.settings.isEmpty ? nil : widget.settings.joined(separator: " · "))
                        }
                        let stays = sharing.widgets.filter { $0.leftOut != nil || !$0.settingsLeftOut.isEmpty }
                        if !stays.isEmpty {
                            Text("Stays on your Mac")
                                .font(.system(size: 11.5, weight: .semibold))
                                .opacity(0.6)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(Array(stays.enumerated()), id: \.offset) { _, widget in
                                SharedRow(symbol: widget.symbol, name: widget.name,
                                          detail: widget.leftOut ?? widget.settingsLeftOut.joined(separator: " · "), dimmed: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                }
                .frame(maxHeight: detailsHeight)
            }
        }
    }

    /// `size` scaled to fit in `space`.
    static func fit(_ size: CGSize, in space: CGSize) -> CGSize {
        let scale = max(0, min(space.width / size.width, space.height / size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func copy() {
        guard let png = share.png else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    private func save() {
        guard let png = share.png else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StableBar.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url) } catch { NSAlert(error: error).runModal() }
    }

    /// Copies the image, which a compose page can't take, and opens `network`'s with the caption and the bar link.
    private func post(to network: BarShareNetwork) {
        copy()
        NSWorkspace.shared.open(network.compose(share.caption, link: share.linkURL))
        note = "Image copied: paste it into your post with ⌘V"
    }

    private func more() {
        guard let png = share.png else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "StableBar.png")
        do {
            try png.write(to: url)
            // With text, the menu leaves out only Add to Photos. With a URL, it would also leave out Notes and Freeform.
            NSSharingServicePicker(items: [url, share.post]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// A card above Share My Bar's toolbar.
private struct ShareCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(width: 360, alignment: .leading)
            .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

/// Moves the window when dragged, wherever no control above it takes the click. A window's
/// `isMovableByWindowBackground` doesn't move it from SwiftUI content.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// A row of "What it shares": the look, a widget the link carries, or what stays on this Mac.
private struct SharedRow: View {
    let symbol: String
    let name: String
    var store = false
    var detail: String?
    var dimmed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).lineLimit(1)
                    if store { PackageOriginBadge(source: .store) }
                }
                if let detail { Text(detail).font(.system(size: 11)).opacity(0.6).lineLimit(1) }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Color.white.opacity(0.08).frame(height: 1) }
    }
}
