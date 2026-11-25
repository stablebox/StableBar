import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

@MainActor let barShare = BarShareWindow()

@MainActor
final class BarShareWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var store: BarStore?
    /// The dock in the panel's place while a post is open in the browser, with the panel hidden.
    private var dock: NSPanel?

    /// Opens Share My Bar on `screen`'s bar, or shows that bar in it when it's already open.
    func show(store: BarStore, screen: NSScreen) {
        self.store = store
        store.barEditing.end()
        closeDock()
        // The last share's images, which no post reads anymore. The first share finds no folder.
        try? FileManager.default.removeItem(at: BarShare.pngFolder)
        let display = BarDisplay(screen: screen)
        let share = BarShare(store: store, display: display, screen: screen.frame.size, menuBar: screen.menuBarHeight,
                             wallpaper: NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:)),
                             menuBarScheme: MenuBarAppearance.shared.schemes[display.id], defaults: .standard)
        let host = NSHostingView(rootView: BarShareView(share: share, close: { [weak self] in self?.window?.performClose(nil) },
                                                        tooltip: { [weak store] text, anchor, inside in
            guard let store else { return }
            store.popup.hover(inside, store: store, anchor: anchor) { store.popup.showTooltip(text, store: store, anchor: anchor) }
        }, posted: { [weak self] in self?.stepAside(share) }))
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

    /// Shrinks the panel into the dock in its place while a post opens in the browser, to drag the image into the post
    /// from.
    private func stepAside(_ share: BarShare) {
        let window = window!
        let panel = window.frame
        let host = NSHostingView(rootView: BarShareDock(share: share, expand: { [weak self] in self?.bringBack() },
                                                       close: { [weak self] in self?.window?.close() }))
        let size = host.fittingSize
        let frame = NSRect(x: panel.midX - size.width / 2, y: panel.midY - size.height / 2, width: size.width, height: size.height)
        // Non-activating, so the browser keeps the keyboard for the post.
        let dock = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dock.isOpaque = false
        dock.backgroundColor = .clear
        dock.hasShadow = true
        dock.level = .floating
        dock.hidesOnDeactivate = false
        dock.isReleasedWhenClosed = false
        dock.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dock.contentView = host
        closeDock()
        self.dock = dock
        let animation = store!.configuration!.bar(on: ScreenKind(BarDisplay(screen: window.screen!))).motion.popupAnimation
        let shrinks = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        dock.alphaValue = 0
        dock.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animation.duration
            context.timingFunction = animation.timingFunction
            dock.animator().alphaValue = 1
            if shrinks { window.animator().setFrame(frame, display: true) }
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                // Show Share My Bar may have brought the panel back already.
                if self?.dock === dock { window.orderOut(nil) }
                // Back as it was, for Show Share My Bar.
                window.setFrame(panel, display: false)
                window.alphaValue = 1
            }
        }
    }

    /// Shows the panel again in place of the dock.
    func bringBack() {
        closeDock()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func closeDock() {
        guard let dock else { return }
        self.dock = nil
        NSAnimationContext.runAnimationGroup { _ in
            dock.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in dock.close() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        closeDock()
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
        return URL(string: "\(page)?\(query(fields))")!
    }
}

/// `fields` as a URL's query, leaving out those without a value.
private func query(_ fields: [(String, String?)]) -> String {
    // In a value, `&` and `=` would end it, and `+` would read as a space.
    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
    return fields.compactMap { name, value in value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)" } }
        .joined(separator: "&")
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
    static let shortensKey = "shareMyBarShortensLink"

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
    /// Whether posts carry the bar link shortened by is.gd, remembered for the next share.
    var shortens: Bool {
        didSet { defaults?.set(shortens, forKey: Self.shortensKey) }
    }
    /// The bar link as is.gd shortened it, or why it couldn't. Nil while it's asked.
    private(set) var shortLink: Result<URL, Error>?
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
        shortens = defaults?.bool(forKey: Self.shortensKey) ?? false
    }

    /// The bar link, unless the bar can't be shared as one.
    var linkURL: URL? { (try? link?.get())?.link }

    /// The link a post carries: the bar link, shortened when `shortens` and is.gd could.
    var postLink: URL? { shortens ? (try? shortLink?.get()) ?? linkURL : linkURL }

    /// The caption and the link, as Copy Caption and the macOS share menu give them.
    var postText: String { [caption, postLink?.absoluteString].compactMap { $0 }.joined(separator: " ") }

    /// Asks is.gd for a short link to the bar link, when `shortens`.
    func shorten() async {
        shortLink = nil
        guard shortens, let linkURL else { return }
        let result: Result<URL, Error>
        do { result = .success(try await Self.shortened(linkURL)) } catch { result = .failure(error) }
        guard !Task.isCancelled else { return }
        shortLink = result
    }

    /// `link` shortened by is.gd, whose short link leads to it with its fragment, which carries the bar.
    nonisolated static func shortened(_ link: URL) async throws -> URL {
        let request = URL(string: "https://is.gd/create.php?" + query([("format", "simple"), ("url", link.absoluteString)]))!
        let (data, response) = try await URLSession.shared.data(from: request)
        // The short link, or the error in words.
        let reply = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let short = URL(string: reply) else {
            throw CommandFailure(message: "is.gd: \(reply)")
        }
        return short
    }

    /// Where the shared images go, emptied each time Share My Bar opens.
    static let pngFolder = FileManager.default.temporaryDirectory.appending(path: "Share My Bar", directoryHint: .isDirectory)

    /// Writes `png` to a file of its own in `pngFolder`, for the share menu and a drag into a post: a later one mustn't
    /// replace the image that an earlier share or drop still reads.
    static func pngFile(_ png: Data) throws -> URL {
        let folder = pngFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "StableBar.png")
        try png.write(to: url)
        return url
    }

    func copyImage() {
        guard let png else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    /// Copies the image, which a compose page can't take, and opens `network`'s with the caption and the link.
    func post(to network: BarShareNetwork) {
        copyImage()
        NSWorkspace.shared.open(network.compose(caption, link: postLink))
    }

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
        let filled = CGSize(width: size.width, height: max(screen.height, size.height))
        let desktop = BarView(store: store, display: display, preview: true)
            .padding(bottom ? .bottom : .top, edge)
            .frame(width: filled.width, height: filled.height)
            .coordinateSpace(.named(GlassBackdrop.space))
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
            .environment(\.glassBackdrop, (wallpaper ?? OffscreenSnapshot.wallpaper).flatMap { Self.glassBackdrop($0, filling: filled) })
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

    /// `wallpaper` blurred as Liquid Glass blurs it, for a wallpaper that fills `size` points.
    private static func glassBackdrop(_ wallpaper: NSImage, filling size: CGSize) -> GlassBackdrop? {
        let image = wallpaper.cgImage(forProposedRect: nil, context: nil, hints: nil)
        // One pixel to a point of the wallpaper as drawn: the blur leaves no finer detail.
        let fill = max(size.width / wallpaper.size.width, size.height / wallpaper.size.height)
        return image.flatMap { image in
            let scale = wallpaper.size.width * fill / CGFloat(image.width)
            let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: small.extent)
            return CIContext().createCGImage(blurred, from: small.extent)
        }
        .map { GlassBackdrop(image: NSImage(cgImage: $0, size: .zero), size: size) }
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
    /// Shows or hides StableBar's tooltip under a view, as the bar's widgets do.
    var tooltip: (String, NSView, Bool) -> Void = { _, _, _ in }
    /// Called once a post opens in the browser.
    var posted: () -> Void = {}
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
        .modifier(BarTooltip(text: "The screen, its notch and the StableBar badge", hover: tooltip))
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
                        // Into a post, whose page can't take the image from its link.
                        .onDrag { share.png.flatMap { try? BarShare.pngFile($0) }.flatMap(NSItemProvider.init(contentsOf:)) ?? NSItemProvider() }
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
                        .pixelBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .padding(-4)
                        .overlay(alignment: .topLeading) {
                            Button { share.badge = false } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .heavy))
                                    .frame(width: 18, height: 18)
                                    .background(Color(white: 0.17), in: Circle())
                                    .overlay(Circle().pixelBorder(.white.opacity(0.9), width: 1.5))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .modifier(BarTooltip(text: "Remove the StableBar badge", hover: tooltip))
                            .offset(x: -13, y: -13)
                            .accessibilityLabel("Remove StableBar Badge")
                        }
                } else {
                    Button { share.badge = true } label: {
                        Label("Badge", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay(Capsule().pixelBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .modifier(BarTooltip(text: "Add the StableBar badge", hover: tooltip))
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
                    .modifier(BarTooltip(text: preset.help, hover: tooltip))
                    .accessibilityLabel(preset.title)
                    .accessibilityAddTraits(share.format.preset == preset ? .isSelected : [])
            }
            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 20).padding(.horizontal, 6)
            tool("doc.on.doc", "Copy Image", action: share.copyImage).disabled(share.image == nil)
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
            .modifier(BarTooltip(text: "Post the image and the bar link", hover: tooltip))
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
        .modifier(BarTooltip(text: title, hover: tooltip))
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
                    if case let .failure(error)? = share.link {
                        Text(errorMessage(error))
                    } else if share.shortens, case let .failure(error)? = share.shortLink {
                        Text("Couldn't shorten the link. \(errorMessage(error))")
                    } else if share.shortens, share.shortLink == nil {
                        Text("Shortening…")
                    } else if let link = share.postLink {
                        Text(link.absoluteString).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                Toggle("Shorten with is.gd", isOn: $share.shortens)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).pixelBorder(.white.opacity(0.12)))
            // While the image redraws, the link is still the last screen's.
            let ready = share.image != nil && !(share.shortens && share.linkURL != nil && share.shortLink == nil)
            HStack(spacing: 6) {
                ForEach(BarShareNetwork.allCases) { network in
                    NetworkButton(network: network) { post(to: network) }
                        .modifier(BarTooltip(text: "Copy the image and post on \(network.name)", hover: tooltip))
                }
            }
            .disabled(!ready)
            Label(note ?? "Each copies the image: paste it into the post with ⌘V, or drag it in from the preview.",
                  systemImage: note == nil ? "info.circle" : "checkmark")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 6) {
                Button("Copy Image") {
                    share.copyImage()
                    note = "Image copied"
                }
                .disabled(share.image == nil)
                Button("Copy Caption") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(share.postText, forType: .string)
                    note = "Caption and link copied"
                }
                .disabled(!ready)
                Spacer(minLength: 0)
                Button("More…", action: more).background(MenuAnchor(view: anchor)).disabled(!ready)
            }
            .buttonStyle(GlassButtonStyle(selected: false, size: .compact))
        }
        .modifier(ShareCard())
        .task(id: share.shortens ? share.linkURL : nil) { await share.shorten() }
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

    private func save() {
        guard let png = share.png else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StableBar.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url) } catch { NSAlert(error: error).runModal() }
    }

    private func post(to network: BarShareNetwork) {
        share.post(to: network)
        posted()
    }

    private func more() {
        guard let png = share.png else { return }
        do {
            // With text, the menu leaves out only Add to Photos. With a URL, it would also leave out Notes and Freeform.
            NSSharingServicePicker(items: [try BarShare.pngFile(png), share.postText]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
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
            .overlay(RoundedRectangle(cornerRadius: 12).pixelBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

/// What Share My Bar shrinks into while a post is open in the browser: the image to drag into the post, the networks to
/// post it on as well, and buttons back to the panel and to close.
struct BarShareDock: View {
    let share: BarShare
    var expand: () -> Void = {}
    var close: () -> Void = {}
    @State private var dropped = false

    var body: some View {
        HStack(spacing: 14) {
            if let image = share.image, let drawn = share.drawn {
                let fit = BarShareView.fit(drawn.size, in: CGSize(width: 134, height: 48))
                // The whole tile drags the image, which can be a thin strip.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(width: 150, height: 64)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).pixelBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .overlay(ImageDragSource(share: share) { dropped = true })
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(dropped ? "Added to your post" : "Drag the image into your post, or press ⌘V",
                      systemImage: dropped ? "checkmark" : "arrow.up.forward")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 2) {
                    ForEach(BarShareNetwork.allCases) { network in
                        NetworkButton(network: network) { share.post(to: network) }
                    }
                }
            }
            VStack(spacing: 4) {
                GlassCloseButton(title: "Close", action: close)
                Button(action: expand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(GlassButtonStyle(selected: false, round: true, size: .compact))
                .accessibilityLabel("Show Share My Bar")
            }
        }
        .padding(12)
        .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).pixelBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .fixedSize()
        .task(id: dropped) {
            guard dropped else { return }
            try? await Task.sleep(for: .seconds(1))
            close()
        }
    }
}

/// A network's round button: its logo, or its name where the app's resources aren't bundled, as in tests.
private struct NetworkButton: View {
    let network: BarShareNetwork
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let logo = network.logo {
                Image(nsImage: logo).renderingMode(.template).resizable().frame(width: 16, height: 16).frame(width: 40)
            } else {
                Text(network.name).padding(.horizontal, 12)
            }
        }
        .buttonStyle(GlassButtonStyle(selected: false, round: true))
        .accessibilityLabel("Post on \(network.name)")
    }
}

/// Drags `share`'s image out as a PNG file, which a web page takes as an upload, and calls `dropped` once it lands.
private struct ImageDragSource: NSViewRepresentable {
    let share: BarShare
    let dropped: () -> Void

    final class DragView: NSView, NSDraggingSource {
        let share: BarShare
        var dropped: () -> Void = {}

        init(share: BarShare) {
            self.share = share
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("DragView is created programmatically.") }

        // The first click starts the drag, though the dock never makes StableBar active.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            guard let png = share.png, let file = try? BarShare.pngFile(png) else { return }
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            // Beside the file, for a page that only reads image data.
            item.setData(png, forType: .png)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(data: png)!
            let fit = BarShareView.fit(image.size, in: bounds.size)
            dragging.setDraggingFrame(NSRect(x: bounds.midX - fit.width / 2, y: bounds.midY - fit.height / 2, width: fit.width, height: fit.height),
                                      contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if operation != [] { dropped() }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView(share: share) }

    func updateNSView(_ view: DragView, context: Context) {
        view.dropped = dropped
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
