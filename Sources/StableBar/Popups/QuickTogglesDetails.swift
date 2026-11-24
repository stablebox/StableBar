import SwiftUI

/// The Quick toggles widget's panel, in cards like the Sound details' and in the theme's colors. A tile this Mac can't use
/// hides.
struct QuickTogglesDetails: View {
    let tiles: [QuickTile]
    let style: WidgetStyle
    let context: BlockContext
    let appearance: WidgetAppearance
    private let toggles = QuickToggles.shared
    /// Wi-Fi, Bluetooth, the network or Keep awake, whose details show.
    @State private var expanded: QuickTile?
    /// The display whose resolutions show.
    @State private var expandedDisplay: CGDirectDisplayID?
    @State private var confirmsTrash = false
    /// Whether Bluetooth's button was clicked while macOS doesn't let StableBar turn it on or off.
    @State private var explainsBluetooth = false
    /// Whether Keep awake lists the apps it can wait for.
    @State private var choosesApp = false
    @State private var password = ""
    @FocusState private var typesPassword: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fixedDate) private var fixedDate

    init(tiles: [QuickTile], style: WidgetStyle, context: BlockContext, appearance: WidgetAppearance) {
        self.tiles = tiles
        self.style = style
        self.context = context
        self.appearance = appearance
        // A join left asking for a password opens with the networks shown.
        _expanded = State(initialValue: QuickToggles.shared.opensExpanded ?? (QuickToggles.shared.join.mode == .idle ? nil : .wifi))
        _expandedDisplay = State(initialValue: QuickToggles.shared.displays.opensExpanded)
    }

    var body: some View {
        let shown = tiles.filter(isShown)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups(of: shown), id: \.self) { group in
                let members = shown.filter { $0.group == group }
                switch group {
                case .connectivity: connectivity(members)
                case .keepAwake: keepAwakeCard
                case .display: displayCard(members)
                case .system: card { switches(members) }
                case .tools: tools(members)
                }
            }
            if let error = toggles.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .task {
            if tiles.contains(.bluetooth) { context.refreshProvider(DataSourceType.bluetooth.name) }
            await toggles.follow()
        }
    }

    /// The groups of `shown`, in the order their first tile comes.
    private func groups(of shown: [QuickTile]) -> [QuickTile.Group] {
        var groups: [QuickTile.Group] = []
        for tile in shown where !groups.contains(tile.group) { groups.append(tile.group) }
        return groups
    }

    private func isShown(_ tile: QuickTile) -> Bool {
        switch tile {
        case .wifi: wifi != nil
        case .bluetooth: bluetooth != nil
        case .network, .keepAwake: true
        case .brightness: !toggles.displays.displays.isEmpty
        case .mirror: toggles.displays.displays.count > 1
        case .lockScreen: PrivateAPI.lockScreenImmediate != nil
        case .ejectDisks: !toggles.ejectable.isEmpty
        case _ where tile.group == .tools: true
        default: toggles.states[tile] != nil
        }
    }

    private var wifi: [String: String]? { context.providerOutput(DataSourceType.wifi.name).map { $0.fields ?? [:] } }
    /// The bluetooth provider's power and devices, which macOS shares without the access turning Bluetooth on or off needs.
    private var bluetooth: ScriptOutput? { context.providerOutput(DataSourceType.bluetooth.name) }
    private var devices: [[String: String]] { bluetooth?.lists?["devices"] ?? [] }

    /// The cards' corners, which the highlights inside them share, from the theme's.
    private var cardRadius: Double { max(appearance.cornerRadius - 2, 0) }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: cardRadius).fill(appearance.foreground.opacity(0.07)))
    }

    private func isOn(_ tile: QuickTile) -> Bool {
        switch tile {
        case .wifi: wifi?["power"] == "on"
        case .bluetooth: toggles.states[.bluetooth] ?? (bluetooth?.fields?["power"] == "on")
        case .keepAwake: toggles.keepAwake.state.mode != .off
        case .mirror: toggles.displays.mirrored
        default: toggles.states[tile] == true
        }
    }

    /// What a wide toggle says under its name.
    private func status(_ tile: QuickTile) -> String {
        switch tile {
        case .wifi:
            let name = wifi?["ssid"] ?? ""
            return !isOn(.wifi) ? "Off" : !name.isEmpty ? name : wifi?["rssi"] != nil ? "Connected" : "Not connected"
        case .bluetooth:
            return !isOn(.bluetooth) ? "Off" : devices.isEmpty ? "On" : devices.count == 1 ? "1 device" : "\(devices.count) devices"
        case .network:
            return toggles.localAddress?.address ?? "Offline"
        case .keepAwake:
            let state = toggles.keepAwake.state
            switch state.mode {
            case .off: return "Off"
            case _ where state.holding == nil: return "Paused on battery"
            case .on(.minutes, _):
                let minutes = state.minutesLeft(at: fixedDate ?? .now)!
                return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
            case let .on(.appQuits(app), _): return "Until \(app.name) quits"
            case .on: return "Until turned off"
            }
        default:
            return isOn(tile) ? "On" : "Off"
        }
    }

    private func toggle(_ tile: QuickTile) {
        switch tile {
        case .wifi: context.runAction(.set(.wifiPower), ["VALUE": String(!isOn(.wifi))])
        case .keepAwake: if isOn(.keepAwake) { toggles.keepAwake.turnOff() } else { toggles.keepAwake.turnOn(.turnedOff) }
        case .network: expand(.network)
        case .mirror: toggles.setMirrored(!isOn(.mirror))
        case .bluetooth:
            guard ![.denied, .restricted].contains(toggles.bluetoothAccess) else {
                withAnimation(reduceMotion ? nil : WidgetAnimation().value) { explainsBluetooth = true }
                return
            }
            let change = toggles.toggle(.bluetooth, from: isOn(.bluetooth))
            Task {
                await change?.value
                context.refreshProvider(DataSourceType.bluetooth.name)
                if toggles.bluetoothAccess == .denied { withAnimation(reduceMotion ? nil : WidgetAnimation().value) { explainsBluetooth = true } }
            }
        default: toggles.toggle(tile, from: isOn(tile))
        }
    }

    /// Shows or hides the details of Wi-Fi, Bluetooth, the network or Keep awake.
    private func expand(_ tile: QuickTile) {
        withAnimation(reduceMotion ? nil : WidgetAnimation().value) { expanded = expanded == tile ? nil : tile }
        if expanded == .wifi { toggles.showNetworks() }
    }

    private func expandable(_ tile: QuickTile) -> Bool {
        tile == .keepAwake || tile == .network || isOn(tile)
    }

    // MARK: Cards

    private func connectivity(_ members: [QuickTile]) -> some View {
        card {
            ForEach(runs(members, apart: .network), id: \.self) { run in
                if run == [.network] {
                    pill(.network)
                } else {
                    HStack(spacing: 8) { ForEach(run, id: \.self) { pill($0) } }
                }
            }
            if explainsBluetooth {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow StableBar under Bluetooth to turn it on or off from here.").font(.system(size: 11)).opacity(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                    link("Privacy & Security…", "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
                }
                .transition(.opacity)
            }
            ForEach(members, id: \.self) { details(of: $0) }
        }
    }

    private var keepAwakeCard: some View {
        card {
            if case .on(.minutes, _) = toggles.keepAwake.state.mode {
                // Counts the minutes left down while the panel stays open.
                TimelineView(.periodic(from: .now, by: 30)) { _ in pill(.keepAwake) }
            } else {
                pill(.keepAwake)
            }
            details(of: .keepAwake)
        }
    }

    @ViewBuilder private func details(of tile: QuickTile) -> some View {
        if expanded == tile, expandable(tile) {
            Group {
                switch tile {
                case .wifi: networks(wifi ?? [:])
                case .bluetooth: bluetoothDevices
                case .network: networkDetails
                default: keepAwakeOptions
                }
            }
            .transition(.opacity)
        }
    }

    /// Each display's brightness, the display's switches, and Night Shift's warmth while it's on.
    private func displayCard(_ members: [QuickTile]) -> some View {
        card {
            ForEach(runs(members, apart: .brightness), id: \.self) { run in
                if run == [.brightness] {
                    ForEach(toggles.displays.displays) { display(row: $0) }
                } else {
                    switches(run)
                }
            }
            if members.contains(.nightShift), isOn(.nightShift), let warmth = toggles.nightShiftStrength {
                slider("Night Shift warmth", symbol: QuickTile.nightShift.symbol) {
                    level(warmth, title: "Night Shift warmth", symbol: "thermometer.sun.fill") { toggles.setNightShiftStrength($0) }
                }
                .transition(.opacity)
            }
        }
    }

    /// `members` in their order, `wide`, which a card draws across, alone, and the tiles between in runs.
    private func runs(_ members: [QuickTile], apart wide: QuickTile) -> [[QuickTile]] {
        var runs: [[QuickTile]] = []
        for tile in members {
            if tile == wide || runs.last == nil || runs.last == [wide] { runs.append([tile]) } else { runs[runs.count - 1].append(tile) }
        }
        return runs
    }

    @ViewBuilder private func switches(_ members: [QuickTile]) -> some View {
        if !members.isEmpty {
            // Up to three in a row, four in two.
            rows(members, columns: members.count == 4 ? 2 : min(members.count, 3), spacing: 6) { tile in
                Chip(tile: tile, on: isOn(tile), radius: min(cardRadius, 8), appearance: appearance) { toggle(tile) }
            }
        }
    }

    /// A display's name, and its resolution, which opens the others, over its brightness.
    private func display(row display: DisplayControls.Display) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            slider(display.name, symbol: display.builtIn ? "laptopcomputer" : "display") {
                level(display.level, title: "\(display.name) brightness", symbol: QuickTile.brightness.symbol) {
                    toggles.displays.setLevel($0, of: display.id)
                }
            } accessory: {
                if display.modes.count > 1, let mode = display.mode {
                    Button {
                        withAnimation(reduceMotion ? nil : WidgetAnimation().value) { expandedDisplay = expandedDisplay == display.id ? nil : display.id }
                    } label: {
                        HStack(spacing: 3) {
                            Text(verbatim: "\(mode.width) × \(mode.height)").monospacedDigit()
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(expandedDisplay == display.id ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if expandedDisplay == display.id {
                VStack(spacing: 2) {
                    ForEach(display.modes) { mode in
                        SoundDeviceRow(name: resolution(mode, among: display.modes), selected: mode == display.mode, radius: cardRadius,
                                       appearance: appearance) { toggles.setMode(mode, of: display.id) }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// A mode's size, and at the ends and for the default, what System Settings calls it.
    private func resolution(_ mode: DisplayModeOption, among modes: [DisplayModeOption]) -> String {
        let size = "\(mode.width) × \(mode.height)"
        if mode == modes.first { return "\(size) · Larger Text" }
        if mode == modes.last { return "\(size) · More Space" }
        return mode.isDefault ? "\(size) · Default" : size
    }

    /// A slider under its name.
    private func slider(_ title: String, symbol: String, @ViewBuilder _ slider: () -> some View,
                        @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 14)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                accessory()
            }
            .font(.system(size: 11, weight: .medium))
            .opacity(0.7)
            slider()
        }
    }

    private func tools(_ members: [QuickTile]) -> some View {
        card {
            // Up to 7 in a row, more in two even rows.
            rows(members, columns: members.count > 7 ? (members.count + 1) / 2 : members.count, spacing: 8) { tile in
                ToolButton(tile: tile, done: toggles.done == tile, busy: toggles.running.contains(tile), appearance: appearance,
                           hover: context.hoverMenuBarItem) { press(tile) }
            }
            if confirmsTrash { trashQuestion.transition(.opacity) }
            if let color = toggles.pickedColor {
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: color)).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(appearance.foreground.opacity(0.25)))
                    Text("Copied \(QuickToggles.hex(color))").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(appearance.foreground.opacity(0.1)))
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
    }

    /// `tiles` in rows of `columns`, each as wide as the others, the last row's too. Not a lazy grid: the popup scrolls its
    /// content, and while its height animates, a lazy grid would drop the tiles its scroll view clips and add them again
    /// apart from their card.
    private func rows<Cell: View>(_ tiles: [QuickTile], columns: Int, spacing: Double,
                                  @ViewBuilder cell: @escaping (QuickTile) -> Cell) -> some View {
        VStack(spacing: spacing) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: columns)), id: \.self) { start in
                let row = tiles[start..<min(start + columns, tiles.count)]
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { cell($0).frame(maxWidth: .infinity) }
                    ForEach(row.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
    }

    private func press(_ tile: QuickTile) {
        switch tile {
        case .emptyTrash:
            withAnimation(reduceMotion ? nil : WidgetAnimation().value) { confirmsTrash = true }
        case .lockScreen, .sleepDisplay, .screenSaver, .screenshot, .hideApps:
            context.close()
            toggles.press(tile)
        default:
            toggles.press(tile)
        }
    }

    // MARK: Wide toggles

    /// Wi-Fi, Bluetooth or Keep awake as a pill: its button turns it on or off, and its name opens its details.
    private func pill(_ tile: QuickTile) -> some View {
        // Without its private call, Bluetooth still lists its devices, but its button can't turn it on or off.
        let fixed = tile == .bluetooth && PrivateAPI.setBluetoothPowerState == nil
        return HStack(spacing: 8) {
            RoundButton(symbol: tile == .wifi && !isOn(.wifi) ? "wifi.slash" : tile.symbol, active: isOn(tile),
                        label: "\(tile.title): \(status(tile))", appearance: appearance) { toggle(tile) }
                .disabled(fixed)
                .modifier(BarTooltip(text: tile == .network ? (expanded == .network ? "Hide Details" : "Show Details")
                                         : fixed ? "\(tile.title) \(isOn(tile) ? "On" : "Off")"
                                         : "Turn \(tile.title) \(isOn(tile) ? "Off" : "On")", hover: context.hoverMenuBarItem))
            PillLabel(title: tile.title, status: status(tile), expanded: expanded == tile, expandable: expandable(tile), radius: cardRadius,
                      appearance: appearance) { expand(tile) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Details

    /// The network joined, then the networks this Mac knows and the others in range, as Control Center lists them. They
    /// show at once from the last scan, and a new scan updates them in place.
    private func networks(_ fields: [String: String]) -> some View {
        let all = toggles.networks ?? []
        let known = all.filter(\.known)
        let others = all.filter { !$0.known }
        return VStack(alignment: .leading, spacing: 2) {
            if let name = fields["ssid"], !name.isEmpty {
                NetworkRow(network: WiFiNetwork(ssid: name, rssi: fields["rssi"].flatMap(Int.init) ?? -100, secure: false, known: true),
                           current: true, joining: false, radius: cardRadius, appearance: appearance) {}
            }
            if fields["access"] != "granted" {
                Text("Allow StableBar under Location Services to see the networks’ names.").font(.system(size: 11)).opacity(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                link("Privacy Settings…", "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
            } else {
                if !known.isEmpty {
                    sectionTitle("Known Networks")
                    ForEach(known) { network(row: $0) }
                }
                HStack(spacing: 6) {
                    sectionTitle("Other Networks")
                    if toggles.scanning { Spinner().padding(.top, 6) }
                }
                if others.isEmpty, !toggles.scanning {
                    Text("None in range").font(.system(size: 12)).opacity(0.6).padding(.horizontal, 6).padding(.vertical, 4)
                }
                ForEach(others) { network(row: $0) }
            }
            link("Wi-Fi Settings…", "x-apple.systempreferences:com.apple.wifi-settings-extension").padding(.top, 4)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).opacity(0.6).padding(.horizontal, 6).padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func network(row network: WiFiNetwork) -> some View {
        NetworkRow(network: network, current: false, joining: toggles.join.mode == .joining(network.ssid, secured: network.secure),
                   radius: cardRadius, appearance: appearance) {
            // A password typed for one network never goes to another.
            if case let .asking(ssid, _) = toggles.join.mode, ssid != network.ssid { password = "" }
            toggles.choose(network)
        }
        if case let .asking(ssid, wrong) = toggles.join.mode, ssid == network.ssid {
            passwordField(wrong: wrong, known: network.known)
        }
        if case let .failed(ssid, message) = toggles.join.mode, ssid == network.ssid {
            Text(message).font(.system(size: 11)).opacity(0.6).padding(.leading, 38).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Asks for a network's password. macOS joins a network it saved only from its own Wi-Fi menu and settings: no public
    /// call or command uses the saved password.
    private func passwordField(wrong: Bool, known: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(wrong ? "That password didn’t work. Try again."
                 : known ? "macOS keeps saved passwords to itself, so enter it here, or join from Wi-Fi Settings." : "Enter its password.")
                .font(.system(size: 11)).opacity(0.6).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: min(cardRadius, 6)).fill(appearance.foreground.opacity(0.1)))
                    .focused($typesPassword)
                    .onSubmit(joinWithPassword)
                    .onAppear { typesPassword = true }
                AccentButton(title: "Join", appearance: appearance, action: joinWithPassword)
                    .disabled(password.isEmpty)
                Button("Cancel") {
                    password = ""
                    toggles.cancelJoin()
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).opacity(0.7)
            }
        }
        .padding(.leading, 38).padding(.vertical, 4)
    }

    private func joinWithPassword() {
        guard !password.isEmpty else { return }
        toggles.submit(password: password)
        password = ""
    }

    private var bluetoothDevices: some View {
        VStack(alignment: .leading, spacing: 2) {
            if devices.isEmpty { Text("No devices connected").font(.system(size: 12)).opacity(0.6).padding(.vertical, 4) }
            ForEach(Array(devices.enumerated()), id: \.offset) { _, device in
                HStack(spacing: 8) {
                    Image(systemName: device["icon"] ?? QuickTile.bluetooth.symbol).font(.system(size: 12)).frame(width: 22)
                    Text(device["name"] ?? "").font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if let battery = device["battery"], !battery.isEmpty {
                        Text(battery).font(.system(size: 11)).monospacedDigit().opacity(0.6)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
            }
            link("Bluetooth Settings…", "x-apple.systempreferences:com.apple.BluetoothSettings").padding(.top, 4)
        }
    }

    /// The Mac's local address, its public one once asked for, and a speed test, which works on any connection.
    private var networkDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let local = toggles.localAddress {
                address("Local IP", "\(local.address) · \(local.interface)", copying: local.address)
            }
            if let address = toggles.publicAddress {
                self.address("Public IP", address, copying: address)
            } else {
                HStack(spacing: 6) {
                    Text("Public IP").opacity(0.6)
                    Spacer()
                    if toggles.fetchesPublicAddress { Spinner() }
                    SoundLink(title: "Show", appearance: appearance) { toggles.showPublicAddress() }
                }
            }
            if let test = toggles.speedTest {
                info("Speed", [test.download.map { "↓ \(NetworkUnits.bits.rate($0 / 8))" }, test.upload.map { "↑ \(NetworkUnits.bits.rate($0 / 8))" }]
                    .compactMap { $0 }.joined(separator: "  "))
                if let responsiveness = test.responsiveness, let rpm = Int(exactly: responsiveness.rounded(.towardZero)) {
                    info("Responsiveness", "\(rpm) RPM")
                }
            }
            if toggles.testsSpeed {
                HStack(spacing: 6) {
                    Spinner()
                    Text("Testing the speed…").opacity(0.6)
                }
            } else {
                SoundLink(title: toggles.speedTest == nil ? "Test Speed" : "Test Again", appearance: appearance) { toggles.testSpeed() }
                    .padding(.horizontal, -4)
            }
        }
        .font(.system(size: 12))
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).opacity(0.6)
            Spacer()
            Text(verbatim: value).monospacedDigit().lineLimit(1)
        }
    }

    private func address(_ title: String, _ value: String, copying copied: String) -> some View {
        HStack(spacing: 6) {
            Text(title).opacity(0.6)
            Spacer()
            Text(verbatim: value).monospacedDigit().lineLimit(1).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copied, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).opacity(0.6).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Copy \(title)")
        }
    }

    private var keepAwakeOptions: some View {
        let keepAwake = toggles.keepAwake
        let chosen: KeepAwakeState.Until? = if case let .on(until, _) = keepAwake.state.mode { until } else { nil }
        let choices: [(String, String, KeepAwakeState.Until)] = [("15 min", "15 minutes", .minutes(15)), ("1 h", "1 hour", .minutes(60)),
                                                                  ("4 h", "4 hours", .minutes(240)), ("∞", "Until turned off", .turnedOff)]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(choices, id: \.0) { title, label, until in
                    Segment(title: title, label: label, selected: chosen == until, radius: min(cardRadius, 8) - 2, appearance: appearance) {
                        keepAwake.turnOn(until)
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: min(cardRadius, 8)).fill(appearance.foreground.opacity(0.08)))
            SoundLink(title: "Until an app quits…", appearance: appearance) {
                withAnimation(reduceMotion ? nil : WidgetAnimation().value) { choosesApp.toggle() }
            }
            .padding(.horizontal, -4)
            if choosesApp {
                VStack(spacing: 2) {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }, id: \.processIdentifier) { app in
                        let name = app.localizedName ?? app.bundleIdentifier ?? "App"
                        SoundDeviceRow(name: name, selected: chosen == .appQuits(KeepAwakeState.App(pid: app.processIdentifier, name: name)),
                                       radius: cardRadius, appearance: appearance) {
                            keepAwake.turnOn(.appQuits(KeepAwakeState.App(pid: app.processIdentifier, name: name)))
                        }
                    }
                }
                .transition(.opacity)
            }
            option("Let the display sleep", keepAwake.state.options.displaySleeps) { on in
                var options = keepAwake.state.options
                options.displaySleeps = on
                keepAwake.setOptions(options)
            }
            option("Only while on power", keepAwake.state.options.onPowerOnly) { on in
                var options = keepAwake.state.options
                options.onPowerOnly = on
                keepAwake.setOptions(options)
            }
        }
    }

    private func option(_ title: String, _ on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            ThemeSwitch(isOn: on, label: title, appearance: appearance) { set(!on) }
        }
    }

    private var trashQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Empty the Trash? Its items are deleted for good.").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                AccentButton(title: "Empty Trash", appearance: appearance) {
                    confirmsTrash = false
                    toggles.press(.emptyTrash)
                }
                Button("Cancel") { withAnimation(reduceMotion ? nil : WidgetAnimation().value) { confirmsTrash = false } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).opacity(0.7)
            }
        }
    }

    /// A filled slider like Control Center's, drawn as the theme's slider role draws popup sliders, as in the Sound
    /// details.
    private func level(_ value: Double, title: String, symbol: String, set: @escaping (Double) -> Void) -> some View {
        let block = PopupBlock(content: .filledSlider(title: title, source: "level", minimum: 0, maximum: 1, step: 0.01, endStop: nil,
                                                      icon: symbol, action: .set(.volume)),
                               role: .slider, style: WidgetStyle(iconSize: 12, height: 28))
        return PopupBlockView(block: block, inheritedStyle: style, fields: [:],
                              context: BlockContext(values: ["level": value], roles: context.roles, continuousSliders: true, open: { _ in },
                                                    runAction: { _, values in values["VALUE"].flatMap(Double.init).map(set) }))
    }

    private func link(_ title: String, _ target: String) -> some View {
        SoundLink(title: title, appearance: appearance) { context.open(OpenTarget(target)!) }
    }
}

/// A wide toggle's name and what it's doing, which opens its details, with a chevron that says so.
private struct PillLabel: View {
    let title: String
    let status: String
    let expanded: Bool
    let expandable: Bool
    let radius: Double
    let appearance: WidgetAppearance
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(status).font(.system(size: 11)).monospacedDigit().opacity(0.6).lineLimit(1)
                }
                Spacer(minLength: 2)
                if expandable {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).opacity(0.5)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: radius).fill(appearance.foreground.opacity(hovered && expandable ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-4)
        .disabled(!expandable)
        .onHover { hovered = $0 }
        .accessibilityLabel(title).accessibilityValue(status)
        .modifier(FocusRing(cornerRadius: radius))
    }
}

/// A setting as a switch: its symbol and one-line name, tinted with the theme's accent while it's on. A tint keeps the
/// name in the theme's text color, which a light accent such as yellow would wash out.
private struct Chip: View {
    let tile: QuickTile
    let on: Bool
    let radius: Double
    let appearance: WidgetAppearance
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tile.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 14)
                    .foregroundStyle(on ? appearance.accent : appearance.foreground)
                Text(tile.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(on ? appearance.accent.opacity(hovered ? 0.3 : 0.22) : appearance.foreground.opacity(hovered ? 0.14 : 0.09)))
            .overlay { if on { RoundedRectangle(cornerRadius: radius).strokeBorder(appearance.accent.opacity(0.6)) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(tile.help).accessibilityValue(on ? "On" : "Off").accessibilityAddTraits(.isToggle)
        .modifier(FocusRing(cornerRadius: radius))
    }
}

/// A tool's round button, which never stays on: a checkmark shows for a moment once it's done. It shows only its symbol,
/// and its name in StableBar's tooltip.
private struct ToolButton: View {
    let tile: QuickTile
    let done: Bool
    let busy: Bool
    let appearance: WidgetAppearance
    let hover: (String, NSView, Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundFace(symbol: done ? "checkmark" : tile.symbol, active: false, size: 34, appearance: appearance)
                .opacity(busy ? 0.4 : 1)
                .overlay { if busy { Spinner(size: 14) } }
        }
        .buttonStyle(.plain).accessibilityLabel(tile.help)
        .disabled(busy)
        .modifier(BarTooltip(text: tile.title, hover: hover))
        .modifier(FocusRing(cornerRadius: min(appearance.cornerRadius, 17)))
    }
}

/// Shows `text` in StableBar's tooltip under the view while the pointer rests on it, as the bar's widgets do: an app
/// that's never in front gets no system tooltips.
private struct BarTooltip: ViewModifier {
    let text: String
    /// Shows or hides a tooltip under a view.
    let hover: (String, NSView, Bool) -> Void
    @State private var anchor = NSView()

    func body(content: Content) -> some View {
        content
            .background(MenuAnchor(view: anchor))
            .onHover { hover(text, anchor, $0) }
            .onDisappear { hover(text, anchor, false) }
    }
}

/// A spinner drawn by SwiftUI. AppKit's, like any AppKit view in the panel, would draw what comes after it in layers of
/// their own, which move apart from their cards as the panel grows and shrinks.
private struct Spinner: View {
    var size = 10.0
    @Environment(\.fixedDate) private var fixedDate

    var body: some View {
        TimelineView(.animation(paused: fixedDate != nil)) { context in
            Circle().trim(from: 0, to: 0.7)
                .stroke(style: StrokeStyle(lineWidth: max(size / 7, 1.2), lineCap: .round))
                .rotationEffect(.degrees((fixedDate ?? context.date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                .frame(width: size, height: size)
                .opacity(0.6)
        }
        .accessibilityLabel("In progress")
    }
}

/// A switch in the theme's colors: the accent while it's on.
private struct ThemeSwitch: View {
    let isOn: Bool
    let label: String
    let appearance: WidgetAppearance
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Capsule().fill(isOn ? AnyShapeStyle(appearance.accent) : AnyShapeStyle(appearance.foreground.opacity(0.2)))
                .frame(width: 30, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(appearance.accentText).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).padding(2)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityValue(isOn ? "On" : "Off").accessibilityAddTraits(.isToggle)
        .modifier(FocusRing { FocusRingShape(shape: Capsule()) })
    }
}

/// One of Keep awake's durations, tinted with the accent while it's the one chosen, as a switch that's on.
private struct Segment: View {
    let title: String
    let label: String
    let selected: Bool
    let radius: Double
    let appearance: WidgetAppearance
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: max(radius, 0))
                    .fill(selected ? appearance.accent.opacity(0.22) : appearance.foreground.opacity(hovered ? 0.08 : 0)))
                .overlay { if selected { RoundedRectangle(cornerRadius: max(radius, 0)).strokeBorder(appearance.accent.opacity(0.6)) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(FocusRing(cornerRadius: max(radius, 0)))
    }
}

/// A network in the Wi-Fi details: its signal in a circle, filled with the accent for the network joined, its name, and
/// whether it's secured or saved. A click joins it.
private struct NetworkRow: View {
    let network: WiFiNetwork
    let current: Bool
    let joining: Bool
    let radius: Double
    let appearance: WidgetAppearance
    let select: () -> Void
    @State private var hovered = false

    var body: some View {
        if current {
            row.accessibilityElement(children: .combine).accessibilityValue("Connected")
        } else {
            Button(action: select) {
                row
                    .background { if hovered { RoundedRectangle(cornerRadius: radius).fill(appearance.foreground.opacity(0.1)) } }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(network.ssid)
            .accessibilityValue(network.secure ? "Secured" : "")
            .modifier(FocusRing(cornerRadius: radius))
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi", variableValue: network.signal).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(current ? appearance.accentText : appearance.foreground)
                .frame(width: 24, height: 24)
                .background(Circle().fill(current ? AnyShapeStyle(appearance.accent) : AnyShapeStyle(appearance.foreground.opacity(0.1))))
            Text(network.ssid).font(.system(size: 12, weight: current ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if joining {
                Spinner()
            } else if network.secure {
                Image(systemName: "lock.fill").font(.system(size: 10)).opacity(0.5)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
    }
}

/// A button filled with the theme's accent, for what a question confirms.
private struct AccentButton: View {
    let title: String
    let appearance: WidgetAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(appearance.accentText)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(appearance.accent, in: RoundedRectangle(cornerRadius: min(appearance.cornerRadius, 6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
    }
}
