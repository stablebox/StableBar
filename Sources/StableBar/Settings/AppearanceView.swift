import AppKit
import SwiftUI

struct AppearanceView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var advanced: AdvancedSheet?
    @State private var screen: ScreenKind?
    @State private var fontFamilies: [String] = []

    private var store: BarStore { editor.store }
    private var gallery: ThemeGallery { editor.gallery }
    private var document: [String: ConfigurationValue] { screen.flatMap { store.screenDocuments[$0.rawValue] } ?? store.effectiveDocument }
    private var screenTheme: WidgetPackageSelection? {
        let screens = (try? store.effectiveDocument["screens"]?.decoded([String: [String: ConfigurationValue]].self)) ?? [:]
        return screen.flatMap { try? screens[$0.rawValue]?["theme"]?.decoded(WidgetPackageSelection.self) }
    }
    /// The themes the bar uses: every screen's, and those a kind of screen chooses for itself.
    private var themesInUse: Set<String> {
        let screens = (try? store.effectiveDocument["screens"]?.decoded([String: [String: ConfigurationValue]].self)) ?? [:]
        let own = screens.values.compactMap { try? $0["theme"]?.decoded(WidgetPackageSelection.self) }.filter(\.enabled)
        return Set([gallery.selectedKey] + own.map(\.key))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                scopeLine
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 230)
                    .background(SettingsPalette.sidebar)
                Divider()
                ScrollViewReader { scroll in
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if editor.appearanceTab != .themes, screen == nil, editor.editingProfile == nil, let theme = gallery.selectedChoice {
                                    ThemeEditsLine(editor: editor, theme: theme, showsEdits: !gallery.linkedThemeIsActive)
                                }
                                page
                            }
                            .frame(maxWidth: 780)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                            .padding(.bottom, 28)
                            .frame(maxWidth: .infinity)
                        }
                        .id(editor.appearanceTab)
                    }
                    // Outside the scroll view, which a new page replaces, so that the page change doesn't cancel it.
                    .task(id: editor.searchTarget) {
                        guard let target = editor.searchTarget else { return }
                        advanced = AdvancedSheet(rawValue: target)
                        let places: [SettingsSearchResult: (AppearanceTab, String?)] = [
                            .theme: (.themes, nil), .colors: (.colors, nil), .barPlacement: (.bar, "Position"), .barLook: (.bar, "Background"),
                            .glass: (.bar, "Liquid Glass"), .barSize: (.bar, "Size"), .everyWidget: (.widgets, nil),
                            .workspaceStyle: (.widgets, "Workspaces"), .everyGroup: (.groups, nil), .popups: (.popups, nil)
                        ]
                        let place = advanced == nil ? SettingsSearchResult(rawValue: target).flatMap { places[$0] } : (.advanced, nil)
                        if let (tab, group) = place {
                            editor.appearanceTab = tab
                            await Task.yield()
                            if Task.isCancelled { return }
                            if let group { scroll.scrollTo(group, anchor: .top) }
                        }
                        editor.searchTarget = nil
                    }
                }
            }
            .overlay(alignment: .top) { Divider() }
        }
        .task(id: store.pendingLinks.theme?.choice.directory) {
            fontFamilies = NSFontManager.shared.availableFontFamilies
            await gallery.refresh()
            await gallery.loadStore()
        }
        .sheet(item: $advanced) { ThemeAdvancedSheet(editor: editor, sheet: $0, screen: screen) }
        .onChange(of: store.effectiveDocument) { _, _ in gallery.configurationChanged() }
        // Moving a value between the main file and the theme's edits changes no value the bar draws.
        .onChange(of: store.profiles) { _, _ in gallery.configurationChanged() }
        .onChange(of: store.configurationError) { _, _ in gallery.contextChanged() }
        .onChange(of: store.configurationStore.context) { _, _ in gallery.contextChanged() }
        .onChange(of: store.pendingLinks.theme?.choice.directory, initial: true) { _, directory in
            gallery.contextChanged()
            if directory != nil { editor.appearanceTab = .themes }
        }
        .onChange(of: store.pendingLinks.bar?.look.choice.directory, initial: true) { _, directory in
            if directory != nil { editor.appearanceTab = .themes }
        }
        .onChange(of: store.pendingLinks.theme?.state) { _, _ in gallery.contextChanged() }
        // A link that fails shows its error card above the gallery.
        .onChange(of: store.pendingLinks.themeError, initial: true) { _, error in if error != nil { editor.appearanceTab = .themes } }
        .onChange(of: store.pendingLinks.barError, initial: true) { _, error in if error != nil { editor.appearanceTab = .themes } }
    }

    /// The theme, then a row for each part of its look, each with the theme's edits in it.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ListTitle("Theme")
                sidebarRow(.themes, name: gallery.selectedChoice?.manifest.name ?? "Themes", subtitle: AppearanceTab.themes.subtitle)
                ListTitle("Customize")
                ForEach(AppearanceTab.allCases.filter { $0 != .themes }, id: \.self) { tab in
                    let changes = editor.lookChanges(under: paths(for: tab)).count
                    sidebarRow(tab, name: tab.title, subtitle: changeCount(changes) ?? tab.subtitle)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    private func sidebarRow(_ tab: AppearanceTab, name: String, subtitle: String) -> some View {
        let selected = editor.appearanceTab == tab
        return Button { editor.appearanceTab = tab } label: {
            ListRow(selected: selected) { _ in
                WidgetRowLabel(symbol: tab.symbol, text: tab.symbol == nil ? "Aa" : nil, name: name, subtitle: subtitle, selected: selected)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The look paths a tab edits, for its count of the theme's edits.
    private func paths(for tab: AppearanceTab) -> [String] {
        let paths = switch tab {
        case .themes: [String]()
        case .colors: ["tokens", "bar.textFollowsBackground"]
        case .bar: ["bar.style", "bar.glass", "bar.divider"] + ["height", "inset", "spacing", "margin", "marginHorizontal", "marginVertical"].map { "bar.\($0)" }
        case .widgets: ["defaults", "workspaceDefaults"]
        case .groups: ["groupDefaults"]
        case .popups: ["popupDefaults", "bar.popupOffset"]
        case .advanced: ["roles"]
        }
        return paths.map { (screen.map { "screens.\($0.rawValue)." } ?? "") + $0 }
    }

    private var header: some View {
        let bar = editor.fields(["bar"], on: screen, values: editor.values("bar", on: screen))
        let source = store.propertySources(path: bar.path, key: "appearance", defaultsPath: bar.defaultsPath, values: bar.values)
        let saved = try? source.editingValue?.decoded(BarAppearance.self)
        let wallpaperSource = store.propertySources(path: bar.path, key: "followsWallpaper", defaultsPath: bar.defaultsPath, values: bar.values)
        let wallpaper = wallpaperSource.editingValue == .bool(true)
        let choice: LightOrDark = saved == .light ? .light : saved == .dark ? .dark : wallpaper ? .wallpaper : .automatic
        return HStack(spacing: 10) {
            editingMenu
            if let screen, screenTheme != nil {
                Button("Use the theme of every screen") {
                    editor.unset(["screens": .object([screen.rawValue: .object(["theme": .null])])])
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            Spacer()
            let saved = [source.saved, wallpaperSource.saved].compactMap { $0 }
            RevertSettingButton(title: "Appearance", property: source, reset: saved.isEmpty ? nil : { saved.forEach(reset) })
            SettingsSegments(selection: Binding(get: { choice }, set: { next in
                guard next != choice else { return }
                var properties: [String: ConfigurationValue] = ["appearance": next.appearance.map { .string($0.rawValue) } ?? .null]
                if next.appearance == nil, wallpaper != (next == .wallpaper) { properties["followsWallpaper"] = .bool(next == .wallpaper) }
                bar.set(properties)
            }), options: [(.automatic, "Automatic"), (.wallpaper, "Wallpaper"), (.light, "Light"), (.dark, "Dark")], stretches: false)
            .fixedSize()
            .help("Wallpaper: on each display, the bar turns light or dark with the menu bar, which follows the wallpaper.")
        }
    }

    private var hasSetups: Bool { editor.editingProfile == nil && !store.configurationStore.screenSetupsWithOwnBars.isEmpty }
    private var themeProfiles: [ConfigurationProfile] { store.profiles.filter { $0.when?.onlyTheme == nil } }
    private var setupTitle: String {
        store.configurationStore.configurationURL == store.configurationStore.sharedConfigurationURL ? "Shared bar only" : "This setup only"
    }

    private var editingTitle: String {
        var parts = [screen?.screenTitle ?? "All screens"]
        if hasSetups, !editor.themeChangesEveryBar { parts.append(setupTitle.lowercased()) }
        if let profile = editor.editingProfile { parts.append("profile \(profile)") }
        return parts.joined(separator: ", ")
    }

    private var editingMenu: some View {
        Menu {
            Section("Screens") {
                let connected = Set(NSScreen.screens.map { ScreenKind(BarDisplay(screen: $0)) })
                Picker("Screens", selection: $screen) {
                    Text("All screens").tag(ScreenKind?.none)
                    ForEach(ScreenKind.allCases, id: \.self) { kind in
                        Text(connected.contains(kind) ? kind.screenTitle : "\(kind.screenTitle) (not connected)").tag(Optional(kind))
                    }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            if hasSetups {
                Section("Screen setups") {
                    Picker("Screen setups", selection: $editor.themeChangesEveryBar) {
                        Text("All setups").tag(true)
                        Text(setupTitle).tag(false)
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
            if !themeProfiles.isEmpty {
                Section("Profile") {
                    Picker("Profile", selection: Binding(get: { editor.editingProfile ?? "" }, set: {
                        if $0 != (editor.editingProfile ?? "") { $0.isEmpty ? editor.endProfileEditing() : editor.editBar(for: $0) }
                    })) {
                        Text("No profile").tag("")
                        ForEach(themeProfiles, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
        } label: {
            Text("Editing: \(editingTitle)")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder private var scopeLine: some View {
        if let screen {
            ScopeLine(text: "Editing \(screen.phrase) only. Other screens keep their look.", action: "Edit All Screens") { self.screen = nil }
        } else if hasSetups, !editor.themeChangesEveryBar {
            ScopeLine(text: "Changes apply to this setup only. Other setups keep their look.", action: "Apply to All Setups") {
                editor.themeChangesEveryBar = true
            }
        }
    }

    private func themes(_ appearance: BarAppearance) -> some View {
        let sections = gallerySections
        let items = sections.flatMap(\.items)
        return VStack(alignment: .leading, spacing: 10) {
            if let candidate = store.pendingLinks.theme, candidate.state != .used {
                LinkedThemeCard(candidate: candidate, editor: editor, screen: screen, everyBar: editor.themeChangesEveryBar)
                    .id(candidate.choice.directory)
                    .padding(.bottom, 4)
            } else if let message = store.pendingLinks.themeError {
                LinkedThemeErrorCard(message: message) { store.pendingLinks.themeError = nil }
                    .padding(.bottom, 4)
            }
            if let candidate = store.pendingLinks.bar, candidate.state != .used {
                LinkedBarCard(candidate: candidate, editor: editor, screen: screen, everyBar: editor.themeChangesEveryBar)
                    .id(candidate.look.choice.directory)
                    .padding(.bottom, 4)
            } else if let message = store.pendingLinks.barError {
                LinkedThemeErrorCard(message: message) { store.pendingLinks.barError = nil }
                    .padding(.bottom, 4)
            }
            ForEach(sections, id: \.title) { section in
                Text(section.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 8).padding(.horizontal, 2)
                let columns = [GridItem(.adaptive(minimum: 200), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(section.items) { card($0, appearance: appearance) }
                }
            }
            ForEach(items) { item in
                if let error = gallery.error(for: item.id) {
                    Label("\(item.title): \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if gallery.storeUnavailable {
                Text("The Store is unavailable. Your installed themes are ready to use.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var gallerySections: [(title: String, items: [ThemeItem])] {
        let installed = gallery.choices.onePerTheme(keeping: Set([gallery.selectedKey] + (screenTheme.map { [$0.key] } ?? [])))
            .filter { !$0.isBundled }
        let isYours = { (choice: ThemeChoice) in [.installed, .local, .saved, .themeLink, .barLink, .retired].contains(gallery.source(of: choice)) }
        let yours = installed.filter(isYours)
        let fromSources = installed.filter { !isYours($0) }.map(ThemeItem.installed)
            + gallery.storeThemes.map(ThemeItem.store)
        return [("Included", gallery.choices.filter(\.isBundled).map(ThemeItem.installed)),
                ("Yours", yours.map(ThemeItem.installed).sorted { $0.title < $1.title }),
                ("Store", fromSources.sorted { $0.title < $1.title })].filter { !$0.items.isEmpty }
    }

    private func card(_ item: ThemeItem, appearance: BarAppearance) -> ThemeCard {
        let look = gallery.previews[item.id]?.configuration(for: appearance)
        switch item {
        case let .installed(choice):
            let selected = screenTheme.map { $0.enabled ? $0.key : "built-in" } ?? gallery.selectedKey
            return ThemeCard(title: choice.isLegacy ? choice.title : choice.manifest.name, look: look, appearance: appearance,
                             isSelected: selected == choice.key,
                             isEdited: gallery.editedThemes.contains(choice.manifest.id), showsPopup: true,
                             progress: gallery.progress[item.id], error: gallery.error(for: item.id), source: gallery.source(of: choice),
                             showInFinder: choice.isBundled ? nil : { NSWorkspace.shared.activateFileViewerSelecting([choice.directory]) },
                             delete: choice.isBundled ? nil : { Task { await gallery.delete(choice) } }, inUse: themesInUse.contains(choice.key)) {
                gallery.select(choice, on: screen, everyBar: editor.themeChangesEveryBar)
            }
        case let .store(entry):
            return ThemeCard(title: entry.name, look: look, appearance: appearance, showsPopup: true,
                             progress: gallery.progress[item.id],
                             error: gallery.error(for: item.id), isStore: true,
                             source: entry.sourceID == PackageSource.storeID ? nil : .privateSource(gallery.sourceName(entry.sourceID))) {
                Task { await gallery.get(entry, on: screen, everyBar: editor.themeChangesEveryBar) }
            }
        }
    }

    /// The page the sidebar selects: the themes, or one part of the look. Look values stay with the theme; the bar's
    /// position doesn't.
    @ViewBuilder private var page: some View {
        let look = screen.map { store.configuration?.onScreen($0) } ?? store.configuration
        let bar = editor.fields(["bar"], on: screen, values: editor.values("bar", on: screen))
        switch editor.appearanceTab {
        case .themes:
            themes(gallery.previewAppearance)
        case .bar:
            barTab(bar)
        case .widgets:
            let widgets = WidgetsLookSection(style: editor.fields(["defaults"], on: screen, values: editor.values("defaults", on: screen)),
                                             fontFamilies: fontFamilies)
            let workspaces = editor.fields(["workspaceDefaults"], on: screen, values: editor.values("workspaceDefaults", on: screen))
            lookGroup("Every widget", paths: widgets.paths) { widgets.rows }
            lookGroup("Workspaces", paths: [workspaces.path]) {
                WorkspacePresentationFields(store: store, path: workspaces.path, values: workspaces.values, set: workspaces.set, unset: workspaces.unset)
            }
        case .groups:
            let groups = GroupsLookSection(editor: editor,
                                           style: editor.fields(["groupDefaults"], on: screen, values: editor.values("groupDefaults", on: screen)),
                                           flared: look?.groupDefaults.flare != nil, spacing: look?.bar.spacing ?? 8)
            lookGroup("Every group", paths: groups.paths) { groups.rows }
        case .popups:
            let popups = PopupsLookSection(style: editor.fields(["popupDefaults"], on: screen, defaultsPath: "defaults",
                                                                values: editor.values("defaults", on: screen).merging(editor.values("popupDefaults", on: screen)) { $1 }),
                                           spacing: editor.fields(["popupDefaults"], on: screen, values: editor.values("popupDefaults", on: screen)),
                                           bar: bar, fontFamilies: fontFamilies)
            lookGroup("Every popup", paths: popups.paths) { popups.rows }
        case .colors:
            let tokens = editor.fields(["tokens"], on: screen, values: editor.values("tokens", on: screen))
            lookGroup("Colors", paths: [tokens.path, "\(bar.path).textFollowsBackground"]) { colors(tokens, bar: bar) }
        case .advanced:
            let roles = editor.fields(["roles"], on: screen, values: [:])
            lookGroup("Advanced", paths: [roles.path]) { advancedRows }
        }
    }

    /// The bar's position, saved for every theme, then the parts of its look.
    @ViewBuilder private func barTab(_ bar: StyleFields) -> some View {
        let style = editor.fields(["bar", "style"], on: screen, values: (try? bar.values["style"]?.decoded([String: ConfigurationValue].self)) ?? [:])
        let divider = editor.fields(["bar", "divider"], on: screen, values: (try? bar.values["divider"]?.decoded([String: ConfigurationValue].self)) ?? [:])
        let glass = editor.fields(["bar", "glass"], on: screen, values: (try? bar.values["glass"]?.decoded([String: ConfigurationValue].self)) ?? [:])
        SettingsGroup("Position", detail: "The same with every theme") {
            let position = (screen.map { store.configuration?.bar(on: $0) } ?? store.configuration?.bar)?.position ?? .top
            bar.row("Edge", "position") { _ in
                SettingsSegments(selection: bar.stringBinding("position", default: BarPosition.top.rawValue),
                                 options: BarPosition.allCases.map { ($0.rawValue, $0.rawValue.capitalized) }, stretches: false)
            }
            if position == .top {
                bar.toggle("Below the menu bar", "belowMenuBar", default: false,
                           hint: "Starts the bar under each display's macOS menu bar. Where the menu bar hides, the bar stays on the top edge.")
                bar.number("Offset from top", "offset", default: 0, in: 0...200,
                           hint: "Below the menu bar, the offset counts from the bottom of the menu bar.")
            } else {
                bar.number("Offset from bottom", "offset", default: 0, in: 0...200,
                           hint: "Counts from the bottom edge of the display, under the Dock if it shows there.")
            }
        }
        lookGroup("Background", paths: [style.path]) {
            LightDarkHeader()
            style.color("Background", "background")
            style.color("Border color", "borderColor")
            style.number("Border width", "borderWidth", default: 0, in: 0...6, step: 0.5)
            style.row("Border edges", "borderEdges") { _ in
                SettingsSegments(selection: style.stringBinding("borderEdges", default: BarBorderEdges.bottom.rawValue),
                                 options: BarBorderEdges.allCases.map { ($0.rawValue, $0.rawValue.capitalized) }, stretches: false)
            }
            style.number("Corner radius", "cornerRadius", default: 0, in: 0...40, slider: true)
        }
        lookGroup("Liquid Glass", paths: [glass.path]) { self.glass(glass) }
        lookGroup("Size", paths: ["height", "inset", "spacing", "margin", "marginHorizontal", "marginVertical"].map { "\(bar.path).\($0)" }) {
            bar.number("Height", "height", default: 40, in: 16...100, slider: true)
            bar.number("Side inset", "inset", default: 12, in: 0...100, hint: "Space between the bar’s ends and its first and last widgets")
            bar.number("Space between widgets", "spacing", default: 8, in: 0...50)
            bar.margin()
        }
        lookGroup("Divider", paths: [divider.path]) {
            LightDarkHeader()
            divider.color("Color", "background")
            divider.number("Width", "width", default: 1, in: 0...6, step: 0.5)
            divider.number("Height", "height", default: 16, in: 0...100, slider: true)
        }
    }

    /// A group of look rows, with the count of the selected theme's edits under `paths` and Reset while there are some.
    private func lookGroup<Rows: View>(_ title: String, paths: [String], @ViewBuilder rows: () -> Rows) -> some View {
        let changes = editor.lookChanges(under: paths)
        return SettingsGroup(title, detail: changeCount(changes.count), reset: editor.reset(changes, everyBar: editor.themeChangesEveryBar), content: rows)
    }

    @ViewBuilder private func colors(_ tokens: StyleFields, bar: StyleFields) -> some View {
        bar.toggle("Text follows its background", "textFollowsBackground", default: false,
                   hint: "A widget's text turns light or dark where the theme's would be hard to read on what's behind it.")
        LightDarkHeader()
        ForEach(store.themeTokenColors(in: document).filter(\.isShared)) { token in
            let property = store.propertySources(path: tokens.path, key: token.name, defaultsPath: tokens.defaultsPath, values: tokens.values)
            let color = (try? property.editingValue?.decoded(HexColor.self)) ?? token.color
            TokenColorButton(title: token.title, color: color, property: property, reset: property.saved.map { source in { reset(source) } }) {
                tokens.set([token.name: $0])
            }
        }
    }

    @ViewBuilder private func glass(_ glass: StyleFields) -> some View {
        glass.toggle("Use Liquid Glass", "enabled", default: false, hint: "Experimental. Needs macOS 26 or later. The bar’s background tints its glass.")
        if glass.values["enabled"] == .bool(true) {
            glass.percentage("See-through", "transparency", default: 0.3)
            glass.toggle("Widgets", "widgets", default: true)
            glass.toggle("Popups", "popups", default: true)
            glass.toggle("Bar", "bar", default: true)
        }
    }

    @ViewBuilder private var advancedRows: some View {
        SettingRow(title: "Presentation roles", hint: "Shared styles for widgets with a role, such as time or status") {
            Button("Edit…") { advanced = .roles }.controlSize(.small)
        }
        SettingRow(title: "AeroSpace mode names", hint: "Match your mode names to the ones themes style") {
            Button("Edit…") { advanced = .modeAliases }.controlSize(.small)
        }
    }

    private func reset(_ source: PropertyValueSource) {
        do { try store.removePropertySource(source, everyBar: editor.themeChangesEveryBar) }
        catch { store.customizationHistory.error = errorMessage(error) }
    }
}

/// The bar's light or dark: `appearance`, else the system's, or with `followsWallpaper` each display's menu bar's.
private enum LightOrDark: Hashable {
    case automatic, wallpaper, light, dark

    var appearance: BarAppearance? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .automatic, .wallpaper: nil
        }
    }
}

enum AppearanceTab: CaseIterable {
    case themes, colors, bar, widgets, groups, popups, advanced

    var title: String {
        switch self {
        case .themes: "Themes"
        case .colors: "Theme colors"
        case .bar: "Bar"
        case .widgets: "Widgets"
        case .groups: "Groups"
        case .popups: "Popups"
        case .advanced: "Advanced"
        }
    }

    /// The sidebar row's symbol; Widgets shows "Aa" instead.
    @MainActor var symbol: String? {
        switch self {
        case .themes: "photo.on.rectangle"
        case .colors: "paintpalette"
        case .bar: "menubar.rectangle"
        case .widgets: nil
        case .groups: WidgetGrouping.symbol
        case .popups: "bubble.middle.top"
        case .advanced: "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .themes: "Choose another theme"
        case .colors: "Shared by the whole look"
        case .bar: "Position, background, size"
        case .widgets: "Every widget, workspaces"
        case .groups: "Every group"
        case .popups: "Background, text, spacing"
        case .advanced: "Roles, mode names"
        }
    }
}

private enum ThemeItem: Identifiable {
    case installed(ThemeChoice)
    case store(PackageIndex.Entry)

    var id: String {
        switch self {
        case let .installed(choice): choice.key
        case let .store(entry): entry.key
        }
    }

    var title: String {
        switch self {
        case let .installed(choice): choice.title
        case let .store(entry): entry.name
        }
    }
}

enum AdvancedSheet: String, Identifiable {
    case roles, modeAliases

    var id: String { rawValue }
}

struct ThemeAdvancedSheet: View {
    let editor: ConfigurationEditor
    let sheet: AdvancedSheet
    let screen: ScreenKind?
    @State private var fontFamilies: [String] = []
    @State private var selectedRole = PresentationRole.time
    @State private var modeName = ""
    @State private var modeAlias = ""
    @Environment(\.dismiss) private var dismiss

    private var store: BarStore { editor.store }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch sheet {
                case .roles: roles
                case .modeAliases: modeAliases
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .background(SettingsPalette.background)
        .task { fontFamilies = NSFontManager.shared.availableFontFamilies }
    }

    private var roles: some View {
        Section("Presentation roles") {
            Picker("Role", selection: $selectedRole) {
                ForEach(PresentationRole.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0) }
            }
            let role = roleFields(selectedRole)
            role.font(fontFamilies)
            role.weight()
            role.number("Font size", "fontSize", default: 13)
            LightDarkHeader()
            role.color("Text", "foreground")
            role.color("Background", "background")
            role.color("Border", "borderColor")
            role.color("Accent", "accent")
            role.number("Border width", "borderWidth", default: 0)
            role.number("Corner radius", "cornerRadius", default: 0)
            if selectedRole == .slider { role.number("Height", "height", default: 28) }
            role.number("Horizontal padding", "paddingHorizontal", default: 0)
            role.number("Vertical padding", "paddingVertical", default: 0)
            Text(selectedRole == .slider
                 ? "Sliders follow this role unless they set filled or another role. An empty role keeps the native slider."
                 : "Only widgets and layout blocks explicitly assigned this role use it. A bar widget’s role does not style its popup.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var modeAliases: some View {
        let aliases = editor.fields(["modeAliases"], on: screen, values: [:])
        let look = screen.map { store.configuration?.look(on: $0) } ?? store.configuration
        return Section("AeroSpace mode names") {
            ForEach((look?.modeAliases ?? [:]).keys.sorted(), id: \.self) { name in
                let own = store.origins["\(aliases.path).\(name)"]
                let origin = own ?? store.origins["modeAliases.\(name)"]
                OverrideRow(title: name, source: origin.map { "From \(store.sourceText($0))" },
                            reset: own.map(store.setsInMainFile) == true ? { aliases.unset([name: .null]) } : nil) {
                    Text("mode.\(look?.modeAliases[name] ?? "")")
                    Button("Remove") { aliases.set([name: .null]) }
                }
            }
            HStack {
                TextField("Local mode, e.g. tailing", text: $modeName)
                TextField("Alias, e.g. command", text: $modeAlias)
                Button("Set mapping") {
                    aliases.set([modeName: .string(modeAlias)])
                    if editor.error == nil { modeName = ""; modeAlias = "" }
                }.disabled(modeName.isEmpty || modeAlias.isEmpty)
            }
            Text("Your configuration maps mode names; the selected theme controls their colors and borders.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func roleFields(_ role: PresentationRole) -> StyleFields {
        let look = screen.map { store.configuration?.look(on: $0) } ?? store.configuration
        let style = (look?.roleStyle(role).inheriting(look?.defaults ?? WidgetStyle()) ?? WidgetStyle()).configurationValue
        return editor.fields(["roles", role.rawValue], on: screen, defaultsPath: "defaults",
                             values: (try? style.decoded([String: ConfigurationValue].self)) ?? [:])
    }
}

private extension ConfigurationEditor {
    func values(_ key: String, on screen: ScreenKind?) -> [String: ConfigurationValue] {
        let document = screen.flatMap { store.screenDocuments[$0.rawValue] } ?? store.effectiveDocument
        return (try? document[key]?.decoded([String: ConfigurationValue].self)) ?? [:]
    }

    func fields(_ keys: [String], on screen: ScreenKind?, defaultsPath: String? = nil, values: [String: ConfigurationValue]) -> StyleFields {
        let path = (screen.map { ["screens", $0.rawValue] } ?? []) + keys
        let nest = { (properties: [String: ConfigurationValue]) in path.dropFirst().reversed().reduce(properties) { [$1: .object($0)] } }
        return StyleFields(store: store, path: path.joined(separator: "."),
                           defaultsPath: screen == nil ? defaultsPath : keys.joined(separator: "."), values: values,
                           set: { self.changeLook(ConfigurationEdit(action: ConfigurationEdit.Action(rawValue: path[0])!, properties: nest($0)),
                                                  everyBar: self.themeChangesEveryBar) },
                           unset: { self.unset([path[0]: .object(nest($0))]) })
    }

    func unset(_ properties: [String: ConfigurationValue]) {
        changeLook(ConfigurationEdit(action: .unset, properties: properties), everyBar: themeChangesEveryBar)
    }
}

/// A tinted line saying what the page edits when it's less than everything, with the way back.
private struct ScopeLine: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
            Spacer(minLength: 8)
            Button(action, action: perform).controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).pixelBorder(Color.accentColor.opacity(0.35)))
        .padding(.top, 10)
    }
}
