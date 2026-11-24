import Foundation

/// One screen to draw offscreen: a configuration, the sample data its widgets show, and what to draw.
/// `StableBar --render-scenes` reads these from `scenes/`, and scene.schema.json describes them. A scene
/// runs nothing: commands, providers and window managers are replaced by the samples it gives.
struct SceneFile: Decodable {
    enum Draw: String, Decodable, CaseIterable { case bar, editBar, popup, settings, uninstall, update, setup, accessibilityGuide, share, shareLink, barLinkReview }
    enum Appearance: String, Decodable, CaseIterable { case dark, light }
    /// A Settings section, named as the toolbar names it, `feedback` for Send feedback in Help, or `crashes` for Crashes in Status.
    enum Section: String, Decodable, CaseIterable { case general, bar, theme, profiles, packages, help, feedback, crashes }
    /// A tab of a widget's Settings page (content, style, behavior), or, without a widget in the Bar or Theme section, Appearance's
    /// Bar page, which holds what the bar's look and placement tabs held (look, placement).
    enum Tab: String, Decodable, CaseIterable {
        case content, style, behavior, look, placement

        var isBarTab: Bool { [.look, .placement].contains(self) }
    }
    /// The Uninstall sheet's confirmation, or the steps that failed before StableBar quits.
    enum Uninstall: String, Decodable, CaseIterable { case confirm, failed }
    enum StarRequestLine: String, Decodable, CaseIterable {
        case repository, gitHubCLI, thanked

        var state: StarRequest.State {
            switch self {
            case .repository: .repository
            case .gitHubCLI: .gitHubCLI(account: "octocat")
            case .thanked: .thanked(account: "octocat")
            }
        }
    }
    /// A setting in System Settings → Accessibility → Display.
    enum AccessibilityDisplay: String, Decodable, CaseIterable { case increaseContrast, reduceTransparency }
    /// The configuration inline, or the path of a configuration file relative to the scene file.
    enum Configuration: Equatable { case inline([String: ConfigurationValue]), file(String) }

    var configuration: Configuration
    /// Package folders, relative to the scene file, installed as `--install-package` installs them. Packages are read
    /// from beside the configuration, so a scene with packages gives its configuration inline, and it's written to the
    /// scene's work folder. With `barLink` or `shareLink`, they're installed from the Store, and with `barLink` the Store
    /// lists them.
    var packages: [String] = []
    /// Why packages, by their path in `packages`, were installed from no source; the others came from a folder.
    var packageOrigins: [String: PackageInstallRecord.Origin] = [:]
    /// Script outputs keyed by widget id or provider name: an object as a script prints it, or plain text.
    var outputs: [String: ConfigurationValue] = [:]
    /// Graph samples keyed by widget id or provider name.
    var history: [String: [Double]] = [:]
    /// AeroSpace's `list-workspaces --json` objects.
    var workspaces: [ConfigurationValue]?
    /// AeroSpace's `list-windows --json` objects.
    var windows: [ConfigurationValue]?
    /// yabai's `query --spaces` objects, drawn in place of `workspaces`, every space on display 1.
    var yabaiSpaces: [ConfigurationValue]?
    /// yabai's `query --windows` objects.
    var yabaiWindows: [ConfigurationValue]?
    /// The bundle identifier of each yabai window's `pid`, which StableBar otherwise reads from the running apps.
    var yabaiApps: [Int: String] = [:]
    /// Dock badge labels by bundle identifier.
    var dockBadges: [String: String] = [:]
    /// The `window-id` of the window the stand-in window manager reports as focused.
    var focusedWindow: Int?
    /// Switch to Desktop shortcuts enabled on the stand-in Mac, for setup and Settings. All are off by default.
    var desktopShortcuts: [Int] = []
    /// The bundle identifier of the active app, Finder by default.
    var activeApp: String?
    /// The menu a popup scene shows in place of the widget's popup, as an app menu widget opens one.
    var menu: [MenuItem]?
    /// The Sound details' mixer, as on a Mac where its apps play.
    var mixer: Mixer?
    /// The Quick toggles' panel, as on a Mac with these settings.
    var quickToggles: QuickToggles?
    var draw: Draw
    /// The widget whose popup or Settings page to draw, or whose popup the bar shows open.
    var widget: String?
    /// The group whose Settings page to draw, in place of a widget's.
    var group: String?
    /// The view of the widget's popup to draw in place of its layout, for `popup`.
    var view: String?
    /// The Settings section to draw when no widget is named.
    var section: Section?
    /// The tab of the widget's Settings page, or of the bar's when the scene opens the Bar section without a widget.
    var tab: Tab?
    /// The installed package whose settings the Store section shows.
    var package: String?
    /// A linked theme's folder, relative to the scene file, shown above the Theme gallery.
    var themeLink: String?
    /// A bar link's JSON payload, relative to the scene file, shown above the Theme gallery, or whose review `barLinkReview` draws.
    var barLink: String?
    /// The bar link's widgets that its card shows unticked.
    var untickedWidgets: [String] = []
    /// What the Uninstall sheet shows, for `uninstall`.
    var uninstall: Uninstall?
    /// The star request the update popup shows, for `update`.
    var starRequest: StarRequestLine?
    /// The step setup shows and the Mac it shows it on, for `setup`.
    var setup: Setup?
    /// A move row outside Applications, for setup or Settings → General.
    var applicationMove: ApplicationMove?
    enum ApplicationMove: String, Decodable, CaseIterable { case ready, replace, useExisting, failed, moving, setupOpen }
    /// The window manager whose windows start under the bar, which Settings → General warns about.
    var windowsUnderBar: WorkspaceSource?
    /// The window managers Settings General finds; every one when nil, whatever the Mac that draws has.
    var workspaceManagers: [WorkspaceSource]?
    /// The screen Share My Bar draws the bar on.
    var shareScreen = BarShareScreen.this
    /// The shape of the image Share My Bar draws.
    var sharePreset = BarSharePreset.bar
    /// The macOS version for feature availability in setup and Settings, pinned independently of the render host.
    var macOSMajorVersion = 26
    var appearances: [Appearance] = Appearance.allCases
    /// The Accessibility display settings a bar or popup scene draws with, all off by default, whatever the Mac that draws has.
    var accessibilityDisplay: [AccessibilityDisplay] = []
    /// An image, relative to the scene file, drawn behind the bar or popup in place of the setup tour's wallpaper, or
    /// behind the previews of the bar in Settings and setup as the Mac's wallpaper.
    var wallpaper: String?
    var width: Double?
    var height: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, packages, packageOrigins, outputs, history, workspaces, windows, yabaiSpaces, yabaiWindows, yabaiApps, focusedWindow, dockBadges, desktopShortcuts, activeApp, menu, mixer, quickToggles, draw, widget, group, view, section, tab, package, uninstall,
             themeLink, barLink, untickedWidgets, starRequest, setup, applicationMove, windowsUnderBar, workspaceManagers, shareScreen, sharePreset, macOSMajorVersion, appearances,
             accessibilityDisplay, wallpaper, width, height
    }

    /// A step of setup's tour, the choices made before it, and what setup reads from the Mac, pinned so a drawing
    /// doesn't depend on the Mac that draws it.
    struct Setup: Equatable {
        /// The step the tour shows.
        var step = SetupSession.Step.intro
        /// The preset picked on Make it yours.
        var preset: SetupPreferences.Preset?
        /// Whether macOS hides its menu bar automatically.
        var menuBarHides = false
        /// Whether macOS allows StableBar Accessibility, control of System Events and full Calendar access.
        var accessibility = true
        var automation = true
        var calendars = true
        /// Whether Automation's Allow has been clicked on Allow; until then the bar waits on the stage. Once clicked, the
        /// bar is the menu bar, or sits below it when `automation` is false.
        var automationAsked = true
        /// Whether the Mac has an internal battery, which presets add Battery for.
        var battery = true
        /// Whether StableBar runs from an Applications folder, which Open at login needs.
        var inApplications = true
        /// Store entries Make it yours shows under Found on your Mac, as if the Mac had their tools.
        var suggested: [PackageIndex.Entry] = []
        /// The Store's widgets presets can add, as if the Store listed them; without them, the Store can't be reached.
        var storeWidgets: [PackageIndex.Entry]?
    }

    /// Regular apps that talk to CoreAudio, each with its own choice and whether it plays, and the output devices, the
    /// first being the default.
    struct Mixer: Equatable {
        struct App: Equatable {
            var id: String
            var name: String
            var volume: Double?
            var muted: Bool?
            var output: String?
            var playing: Bool?
        }

        struct Output: Equatable {
            var uid: String
            var name: String
        }

        var apps: [App]
        var outputs: [Output]

        /// The mixer's state with these apps running and System Audio Recording allowed.
        var state: MixerState {
            var state = MixerState(settings: Dictionary(uniqueKeysWithValues: apps.compactMap { app in
                let setting = MixerState.Setting(volume: app.volume ?? 1, muted: app.muted ?? false, output: app.output)
                return setting.isDefault ? nil : (app.id, setting)
            }))
            _ = state.handle(.outputsChanged(outputs.map { MixerState.Output(uid: $0.uid, name: $0.name) }, defaultOutput: outputs.first?.uid))
            _ = state.handle(.processesChanged(apps.enumerated().map { MixerState.Client(object: UInt32($0.offset), bundleID: $0.element.id,
                                                                                         name: $0.element.name, playing: $0.element.playing ?? false) },
                                               apps: Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.name) })))
            _ = state.handle(.permissionChecked(.allowed))
            return state
        }
    }

    /// What the Quick toggles' panel shows, without reading or changing the Mac that draws it.
    struct QuickToggles: Equatable {
        /// Each toggle that shows, on or off. The others hide, as on a Mac without them.
        var states: [QuickTile: Bool]
        var brightness: Double?
        /// The minutes Keep awake has left; nil while it's off.
        var keepAwakeMinutes: Int?
        var pickedColor: HexColor?
        /// The names of the disks Eject Disks ejects.
        var disks: [String]
        /// What a Wi-Fi scan found.
        var networks: [WiFiNetwork]?
        /// The network whose password the Wi-Fi card asks for, with its list open.
        var asking: String?
        /// Whether a Wi-Fi scan is under way.
        var scanning: Bool
        /// The tile whose details the panel shows open: wifi, bluetooth, network or keepAwake.
        var expanded: QuickTile?
        /// The displays, the first being the main one; without them, `brightness` is the built-in display's.
        var displays: [Display]
        /// The display whose resolutions the panel shows, by name.
        var expandedDisplay: String?
        var mirrored: Bool
        var nightShiftStrength: Double?
        var network: Network?

        struct Display: Equatable {
            var name: String
            var builtIn: Bool
            var level: Double
            /// Whether the slider sets the display's own brightness, as DDC/CI does when the display answers.
            var ownBrightness: Bool
            /// Sizes in points, such as `1512x982`, drawn at twice as many pixels, from larger text to more space.
            var modes: [String]
            var current: String?
            var defaultMode: String?
        }

        struct Network: Equatable {
            var interface: String
            var address: String
            var publicAddress: String?
            var speedTest: NetworkDetails.SpeedTest?
        }
    }

    /// An item of a sample menu, with the values Accessibility gives a menu item. An empty title is a separator.
    struct MenuItem: Equatable {
        var title: String
        /// `AXMenuItemCmdChar`: the shortcut's character.
        var key: String?
        /// `AXMenuItemCmdVirtualKey`: the virtual key code of a key without a character.
        var virtualKey: Int?
        /// `AXMenuItemCmdGlyph`: the menu glyph of a key without a character.
        var glyph: Int?
        /// `AXMenuItemCmdModifiers`: 0 is ⌘ alone, then 1 adds ⇧, 2 ⌥, 4 ⌃, 8 removes ⌘ and 16 adds fn.
        var modifiers = 0
        var enabled = true
        var checked = false
        var submenu = false
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, allowing: ["$schema"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try? values.decode(String.self, forKey: .configuration) {
            configuration = .file(path)
        } else {
            configuration = .inline(try values.decode([String: ConfigurationValue].self, forKey: .configuration))
        }
        packages = try values.decodeIfPresent([String].self, forKey: .packages) ?? []
        if !packages.isEmpty, case .file = configuration {
            throw DecodingError.dataCorruptedError(forKey: .packages, in: values, debugDescription: "A scene with packages gives its configuration inline.")
        }
        packageOrigins = try values.decodeIfPresent([String: PackageInstallRecord.Origin].self, forKey: .packageOrigins) ?? [:]
        outputs = try values.decodeIfPresent([String: ConfigurationValue].self, forKey: .outputs) ?? [:]
        history = try values.decodeIfPresent([String: [Double]].self, forKey: .history) ?? [:]
        workspaces = try values.decodeIfPresent([ConfigurationValue].self, forKey: .workspaces)
        windows = try values.decodeIfPresent([ConfigurationValue].self, forKey: .windows)
        yabaiSpaces = try values.decodeIfPresent([ConfigurationValue].self, forKey: .yabaiSpaces)
        yabaiWindows = try values.decodeIfPresent([ConfigurationValue].self, forKey: .yabaiWindows)
        yabaiApps = try values.decodeIfPresent([Int: String].self, forKey: .yabaiApps) ?? [:]
        dockBadges = try values.decodeIfPresent([String: String].self, forKey: .dockBadges) ?? [:]
        desktopShortcuts = try values.decodeIfPresent([Int].self, forKey: .desktopShortcuts) ?? []
        if desktopShortcuts.contains(where: { !DesktopShortcuts.desktops.contains($0) }) || Set(desktopShortcuts).count != desktopShortcuts.count {
            throw DecodingError.dataCorruptedError(forKey: .desktopShortcuts, in: values,
                                                   debugDescription: "Desktop shortcuts name desktops 1 to 16, each once.")
        }
        focusedWindow = try values.decodeIfPresent(Int.self, forKey: .focusedWindow)
        activeApp = try values.decodeIfPresent(String.self, forKey: .activeApp)
        menu = try values.decodeIfPresent([MenuItem].self, forKey: .menu)
        mixer = try values.decodeIfPresent(Mixer.self, forKey: .mixer)
        quickToggles = try values.decodeIfPresent(QuickToggles.self, forKey: .quickToggles)
        draw = try values.decode(Draw.self, forKey: .draw)
        widget = try values.decodeIfPresent(String.self, forKey: .widget)
        group = try values.decodeIfPresent(String.self, forKey: .group)
        view = try values.decodeIfPresent(String.self, forKey: .view)
        section = try values.decodeIfPresent(Section.self, forKey: .section)
        tab = try values.decodeIfPresent(Tab.self, forKey: .tab)
        package = try values.decodeIfPresent(String.self, forKey: .package)
        themeLink = try values.decodeIfPresent(String.self, forKey: .themeLink)
        barLink = try values.decodeIfPresent(String.self, forKey: .barLink)
        untickedWidgets = try values.decodeIfPresent([String].self, forKey: .untickedWidgets) ?? []
        uninstall = try values.decodeIfPresent(Uninstall.self, forKey: .uninstall)
        starRequest = try values.decodeIfPresent(StarRequestLine.self, forKey: .starRequest)
        setup = try values.decodeIfPresent(Setup.self, forKey: .setup)
        applicationMove = try values.decodeIfPresent(ApplicationMove.self, forKey: .applicationMove)
        if applicationMove != nil, draw != .setup && !(draw == .settings && section == .general) {
            throw DecodingError.dataCorruptedError(forKey: .applicationMove, in: values,
                debugDescription: "applicationMove draws a setup row or Settings General.")
        }
        // Setup shows the move row only outside Applications, and a setup scene is in Applications by default.
        if applicationMove != nil, draw == .setup, setup?.inApplications != false {
            throw DecodingError.dataCorruptedError(forKey: .applicationMove, in: values,
                debugDescription: "A setup scene draws applicationMove only with setup.inApplications false.")
        }
        windowsUnderBar = try values.decodeIfPresent(WorkspaceSource.self, forKey: .windowsUnderBar)
        if windowsUnderBar != nil, !(draw == .settings && section == .general || draw == .setup) {
            throw DecodingError.dataCorruptedError(forKey: .windowsUnderBar, in: values,
                debugDescription: "windowsUnderBar draws Settings General or setup.")
        }
        workspaceManagers = try values.decodeIfPresent([WorkspaceSource].self, forKey: .workspaceManagers)
        if let workspaceManagers {
            if draw != .settings || section != .general || widget != nil {
                throw DecodingError.dataCorruptedError(forKey: .workspaceManagers, in: values,
                    debugDescription: "workspaceManagers draws Settings General.")
            }
            if workspaceManagers.contains(.spaces) {
                throw DecodingError.dataCorruptedError(forKey: .workspaceManagers, in: values,
                    debugDescription: "workspaceManagers lists window managers; macOS Spaces is always listed.")
            }
        }
        shareScreen = try values.decodeIfPresent(BarShareScreen.self, forKey: .shareScreen) ?? .this
        if values.contains(.shareScreen), draw != .share && draw != .shareLink {
            throw DecodingError.dataCorruptedError(forKey: .shareScreen, in: values, debugDescription: "shareScreen draws share or shareLink.")
        }
        sharePreset = try values.decodeIfPresent(BarSharePreset.self, forKey: .sharePreset) ?? .bar
        if values.contains(.sharePreset), draw != .share && draw != .shareLink {
            throw DecodingError.dataCorruptedError(forKey: .sharePreset, in: values, debugDescription: "sharePreset draws share or shareLink.")
        }
        macOSMajorVersion = try values.decodeIfPresent(Int.self, forKey: .macOSMajorVersion) ?? 26
        if macOSMajorVersion < 14 {
            throw DecodingError.dataCorruptedError(forKey: .macOSMajorVersion, in: values,
                                                   debugDescription: "A macOS major version is 14 or later.")
        }
        appearances = try values.decodeIfPresent([Appearance].self, forKey: .appearances) ?? Appearance.allCases
        if appearances.isEmpty || Set(appearances).count != appearances.count {
            throw DecodingError.dataCorruptedError(forKey: .appearances, in: values,
                                                   debugDescription: "Appearances name dark, light or both, each once.")
        }
        accessibilityDisplay = try values.decodeIfPresent([AccessibilityDisplay].self, forKey: .accessibilityDisplay) ?? []
        wallpaper = try values.decodeIfPresent(String.self, forKey: .wallpaper)
        width = try values.decodeIfPresent(Double.self, forKey: .width)
        height = try values.decodeIfPresent(Double.self, forKey: .height)
        if let width, !(100...4000).contains(width) {
            throw DecodingError.dataCorruptedError(forKey: .width, in: values, debugDescription: "A width is 100 to 4000 points.")
        }
        if let height, !(20...4000).contains(height) {
            throw DecodingError.dataCorruptedError(forKey: .height, in: values, debugDescription: "A height is 20 to 4000 points.")
        }
        if draw == .popup, widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .widget, in: values, debugDescription: "A popup scene names its widget.")
        }
        if draw == .settings, widget == nil, group == nil, section == nil {
            throw DecodingError.dataCorruptedError(forKey: .section, in: values,
                                                   debugDescription: "A settings scene names a widget, a group or a section.")
        }
        if group != nil, draw != .settings || widget != nil || section != nil || tab != nil {
            throw DecodingError.dataCorruptedError(forKey: .group, in: values,
                                                   debugDescription: "group belongs to a settings scene without a widget, a section or a tab.")
        }
        if package != nil, draw != .settings || widget != nil || section != .packages {
            throw DecodingError.dataCorruptedError(forKey: .package, in: values, debugDescription: "package belongs to the packages section of Settings.")
        }
        if themeLink != nil, draw != .settings || widget != nil || section != .theme {
            throw DecodingError.dataCorruptedError(forKey: .themeLink, in: values,
                                                   debugDescription: "themeLink belongs to the theme section of Settings.")
        }
        if barLink != nil, draw != .barLinkReview, draw != .settings || widget != nil || section != .theme {
            throw DecodingError.dataCorruptedError(forKey: .barLink, in: values,
                                                   debugDescription: "barLink belongs to the theme section of Settings or to a barLinkReview scene.")
        }
        if draw == .barLinkReview, barLink == nil {
            throw DecodingError.dataCorruptedError(forKey: .barLink, in: values, debugDescription: "A barLinkReview scene names its barLink.")
        }
        if !untickedWidgets.isEmpty, barLink == nil {
            throw DecodingError.dataCorruptedError(forKey: .untickedWidgets, in: values, debugDescription: "untickedWidgets belongs to a barLink.")
        }
        if menu != nil, draw != .popup {
            throw DecodingError.dataCorruptedError(forKey: .menu, in: values, debugDescription: "A menu belongs to a popup scene.")
        }
        if view != nil, draw != .popup {
            throw DecodingError.dataCorruptedError(forKey: .view, in: values, debugDescription: "A view belongs to a popup scene.")
        }
        if uninstall != nil, draw != .uninstall {
            throw DecodingError.dataCorruptedError(forKey: .uninstall, in: values, debugDescription: "uninstall belongs to an uninstall scene.")
        }
        if starRequest != nil, draw != .update, !(draw == .settings && widget == nil && section == .help) {
            throw DecodingError.dataCorruptedError(forKey: .starRequest, in: values,
                                                   debugDescription: "starRequest belongs to an update scene or to Help in Settings.")
        }
        if setup != nil, draw != .setup {
            throw DecodingError.dataCorruptedError(forKey: .setup, in: values, debugDescription: "setup belongs to a setup scene.")
        }
        if !accessibilityDisplay.isEmpty, draw != .bar, draw != .popup {
            throw DecodingError.dataCorruptedError(forKey: .accessibilityDisplay, in: values,
                                                   debugDescription: "accessibilityDisplay belongs to a bar or popup scene.")
        }
        if wallpaper != nil, ![.bar, .popup, .settings, .setup].contains(draw) {
            throw DecodingError.dataCorruptedError(forKey: .wallpaper, in: values,
                                                   debugDescription: "wallpaper belongs to a bar, popup, settings or setup scene.")
        }
        if let tab, tab.isBarTab, widget != nil || ![.bar, .theme].contains(section) {
            throw DecodingError.dataCorruptedError(forKey: .tab, in: values,
                                                   debugDescription: "\(tab.rawValue) draws Appearance's Bar page, in the bar or theme section without a widget.")
        }
        if let tab, !tab.isBarTab, widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .tab, in: values, debugDescription: "\(tab.rawValue) is a tab of a widget's Settings page.")
        }
    }

    static func read(_ url: URL) throws -> SceneFile {
        try JSONDecoder().decode(SceneFile.self, from: Data(contentsOf: url))
    }
}

extension SceneFile.Setup: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case step, preset, menuBarHides, accessibility, automation, automationAsked, calendars, battery, inApplications, suggested,
             storeWidgets
    }

    /// Steps and presets go by the names the app gives them, such as `allow` or `workday`.
    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func named<Value>(_ key: CodingKeys, among choices: [Value]) throws -> Value? {
            guard let name = try values.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let value = choices.first(where: { "\($0)" == name }) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription:
                    "\(key.stringValue) is one of \(choices.map { "\($0)" }.joined(separator: ", ")).")
            }
            return value
        }
        step = try named(.step, among: SetupSession.Step.allCases) ?? .intro
        preset = try named(.preset, among: SetupPreferences.Preset.allCases)
        menuBarHides = try values.decodeIfPresent(Bool.self, forKey: .menuBarHides) ?? false
        accessibility = try values.decodeIfPresent(Bool.self, forKey: .accessibility) ?? true
        automation = try values.decodeIfPresent(Bool.self, forKey: .automation) ?? true
        automationAsked = try values.decodeIfPresent(Bool.self, forKey: .automationAsked) ?? true
        calendars = try values.decodeIfPresent(Bool.self, forKey: .calendars) ?? true
        battery = try values.decodeIfPresent(Bool.self, forKey: .battery) ?? true
        inApplications = try values.decodeIfPresent(Bool.self, forKey: .inApplications) ?? true
        suggested = try values.decodeIfPresent([PackageIndex.Entry].self, forKey: .suggested) ?? []
        storeWidgets = try values.decodeIfPresent([PackageIndex.Entry].self, forKey: .storeWidgets)
    }
}

extension SceneFile.Mixer: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case apps, outputs }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apps = try values.decode([App].self, forKey: .apps)
        outputs = try values.decode([Output].self, forKey: .outputs)
        if Set(apps.map(\.id)).count != apps.count {
            throw DecodingError.dataCorruptedError(forKey: .apps, in: values, debugDescription: "The mixer names each app once.")
        }
    }
}

extension SceneFile.QuickToggles: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case states, brightness, keepAwakeMinutes, pickedColor, disks, networks, asking, scanning, expanded, displays, expandedDisplay,
                                                       mirrored, nightShiftStrength, network }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        states = [:]
        for (name, on) in try values.decodeIfPresent([String: Bool].self, forKey: .states) ?? [:] {
            guard let tile = QuickTile(rawValue: name), ![.wifi, .network, .keepAwake, .brightness, .mirror].contains(tile), tile.group != .tools else {
                throw DecodingError.dataCorruptedError(forKey: .states, in: values, debugDescription: "\(name) isn't a toggle.")
            }
            states[tile] = on
        }
        brightness = try values.decodeIfPresent(Double.self, forKey: .brightness)
        keepAwakeMinutes = try values.decodeIfPresent(Int.self, forKey: .keepAwakeMinutes)
        pickedColor = try values.decodeIfPresent(HexColor.self, forKey: .pickedColor)
        disks = try values.decodeIfPresent([String].self, forKey: .disks) ?? []
        networks = try values.decodeIfPresent([WiFiNetwork].self, forKey: .networks)
        asking = try values.decodeIfPresent(String.self, forKey: .asking)
        scanning = try values.decodeIfPresent(Bool.self, forKey: .scanning) ?? false
        expanded = try values.decodeIfPresent(QuickTile.self, forKey: .expanded)
        displays = try values.decodeIfPresent([Display].self, forKey: .displays) ?? []
        expandedDisplay = try values.decodeIfPresent(String.self, forKey: .expandedDisplay)
        mirrored = try values.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
        nightShiftStrength = try values.decodeIfPresent(Double.self, forKey: .nightShiftStrength)
        network = try values.decodeIfPresent(Network.self, forKey: .network)
    }
}

extension SceneFile.QuickToggles.Display: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case name, builtIn, level, ownBrightness, modes, current, defaultMode }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        builtIn = try values.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        level = try values.decode(Double.self, forKey: .level)
        ownBrightness = try values.decodeIfPresent(Bool.self, forKey: .ownBrightness) ?? true
        modes = try values.decodeIfPresent([String].self, forKey: .modes) ?? []
        if let size = modes.first(where: { $0.range(of: "^[1-9][0-9]{0,4}x[1-9][0-9]{0,4}$", options: .regularExpression) == nil }) {
            throw DecodingError.dataCorruptedError(forKey: .modes, in: values, debugDescription: "\(size) isn't a size such as 1512x982.")
        }
        current = try values.decodeIfPresent(String.self, forKey: .current)
        defaultMode = try values.decodeIfPresent(String.self, forKey: .defaultMode)
        if let size = ([current, defaultMode].compactMap { $0 }).first(where: { !modes.contains($0) }) {
            throw DecodingError.dataCorruptedError(forKey: .modes, in: values, debugDescription: "\(size) isn't one of the modes.")
        }
    }
}

extension SceneFile.QuickToggles.Network: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case interface, address, publicAddress, download, upload, responsiveness }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        interface = try values.decode(String.self, forKey: .interface)
        address = try values.decode(String.self, forKey: .address)
        publicAddress = try values.decodeIfPresent(String.self, forKey: .publicAddress)
        let test = NetworkDetails.SpeedTest(download: try values.decodeIfPresent(Double.self, forKey: .download),
                                            upload: try values.decodeIfPresent(Double.self, forKey: .upload),
                                            responsiveness: try values.decodeIfPresent(Double.self, forKey: .responsiveness))
        speedTest = test == NetworkDetails.SpeedTest() ? nil : test
    }
}

extension WiFiNetwork: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case ssid, rssi, secure, known }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ssid: try values.decode(String.self, forKey: .ssid), rssi: try values.decode(Int.self, forKey: .rssi),
                  secure: try values.decodeIfPresent(Bool.self, forKey: .secure) ?? true,
                  known: try values.decodeIfPresent(Bool.self, forKey: .known) ?? false)
    }
}

extension SceneFile.Mixer.App: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, volume, muted, output, playing }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        volume = try values.decodeIfPresent(Double.self, forKey: .volume)
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted)
        output = try values.decodeIfPresent(String.self, forKey: .output)
        playing = try values.decodeIfPresent(Bool.self, forKey: .playing)
    }
}

extension SceneFile.Mixer.Output: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case uid, name }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uid = try values.decode(String.self, forKey: .uid)
        name = try values.decode(String.self, forKey: .name)
    }
}

extension SceneFile.MenuItem: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case title, key, virtualKey, glyph, modifiers, enabled, checked, submenu }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        key = try values.decodeIfPresent(String.self, forKey: .key)
        virtualKey = try values.decodeIfPresent(Int.self, forKey: .virtualKey)
        glyph = try values.decodeIfPresent(Int.self, forKey: .glyph)
        modifiers = try values.decodeIfPresent(Int.self, forKey: .modifiers) ?? 0
        if modifiers < 0 {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: values,
                                                   debugDescription: "Modifiers are flags added up from 0.")
        }
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        checked = try values.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        submenu = try values.decodeIfPresent(Bool.self, forKey: .submenu) ?? false
    }
}
