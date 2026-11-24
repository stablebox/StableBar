/// A tile of the Quick toggles widget's panel. `tiles` lists the ones it shows: the panel puts each in its group's card,
/// the cards in the order their first tile comes, and the tiles in a card in their order.
enum QuickTile: String, CaseIterable, Decodable, Sendable {
    case wifi, bluetooth, network, keepAwake, brightness, darkMode, nightShift, trueTone, mirror
    case desktopIcons, dockAutohide, hiddenFiles, microphone
    case lockScreen, sleepDisplay, screenSaver, screenshot, colorPicker, cameraMirror, clearClipboard, hideApps, emptyTrash, ejectDisks

    /// What the panel shows without `tiles`. A tile this Mac can't use, such as True Tone on a Mac without it, hides.
    static let standard: [QuickTile] = [.wifi, .bluetooth, .keepAwake, .brightness, .darkMode, .nightShift, .trueTone, .mirror, .desktopIcons,
                                        .dockAutohide, .lockScreen, .screenshot, .colorPicker, .cameraMirror, .emptyTrash, .ejectDisks]

    /// The card a tile goes in, which decides how it's drawn: connections and Keep awake as wide toggles that open
    /// their details, the displays' brightness as sliders, the display's and the Mac's settings as switches, and the
    /// tools as buttons.
    enum Group {
        case connectivity, keepAwake, display, system, tools

        var title: String {
            switch self {
            case .connectivity: "Connections"
            case .keepAwake: "Keep Awake"
            case .display: "Display"
            case .system: "Desktop"
            case .tools: "Tools"
            }
        }
    }

    var group: Group {
        switch self {
        case .wifi, .bluetooth, .network: .connectivity
        case .keepAwake: .keepAwake
        case .brightness, .darkMode, .nightShift, .trueTone, .mirror: .display
        case .desktopIcons, .dockAutohide, .hiddenFiles, .microphone: .system
        case .lockScreen, .sleepDisplay, .screenSaver, .screenshot, .colorPicker, .cameraMirror, .clearClipboard, .hideApps, .emptyTrash,
             .ejectDisks: .tools
        }
    }

    /// A name that fits on one line of a switch, and says what's on while it's on.
    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .network: "Network"
        case .keepAwake: "Keep Awake"
        case .brightness: "Brightness"
        case .darkMode: "Dark Mode"
        case .nightShift: "Night Shift"
        case .trueTone: "True Tone"
        case .mirror: "Mirror"
        case .desktopIcons: "Hide Icons"
        case .dockAutohide: "Hide Dock"
        case .hiddenFiles: "Dotfiles"
        case .microphone: "Mute Mic"
        case .lockScreen: "Lock Screen"
        case .sleepDisplay: "Sleep Display"
        case .screenSaver: "Screen Saver"
        case .screenshot: "Screenshot"
        case .colorPicker: "Color Picker"
        case .cameraMirror: "Camera"
        case .clearClipboard: "Clear Clipboard"
        case .hideApps: "Hide Apps"
        case .emptyTrash: "Empty Trash"
        case .ejectDisks: "Eject Disks"
        }
    }

    /// What it does in full, for its tooltip and VoiceOver.
    var help: String {
        switch self {
        case .network: "The Mac’s IP addresses and a speed test"
        case .brightness: "Each display’s brightness and resolution"
        case .mirror: "Mirror the displays"
        case .desktopIcons: "Hide the icons on the desktop"
        case .dockAutohide: "Hide the Dock until the pointer reaches it"
        case .hiddenFiles: "Show hidden files in Finder"
        case .microphone: "Mute the microphone"
        case .sleepDisplay: "Turn the displays off"
        case .colorPicker: "Pick a color on screen and copy its hex code"
        case .cameraMirror: "Show the camera in a small window"
        case .hideApps: "Hide every app’s windows"
        case .ejectDisks: "Eject every disk you can eject"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .network: "network"
        case .keepAwake: "cup.and.heat.waves.fill"
        case .brightness: "sun.max.fill"
        case .darkMode: "circle.lefthalf.filled"
        case .nightShift: "moon.stars.fill"
        case .trueTone: "camera.filters"
        case .mirror: "rectangle.on.rectangle"
        case .desktopIcons: "rectangle.dashed"
        case .dockAutohide: "dock.rectangle"
        case .hiddenFiles: "eye"
        case .microphone: "mic.slash.fill"
        case .lockScreen: "lock.fill"
        case .sleepDisplay: "moon.zzz.fill"
        case .screenSaver: "sparkles.tv"
        case .screenshot: "camera.viewfinder"
        case .colorPicker: "eyedropper"
        case .cameraMirror: "web.camera"
        case .clearClipboard: "clipboard"
        case .hideApps: "rectangle.on.rectangle.slash"
        case .emptyTrash: "trash"
        case .ejectDisks: "eject.fill"
        }
    }
}
