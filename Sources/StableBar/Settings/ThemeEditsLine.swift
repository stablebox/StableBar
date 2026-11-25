import SwiftUI

/// Customize's heading for the selected theme, with its edits on the same row: how many there are, Save as Theme and
/// Revert. Show Changes lists each one, then the look values of the main file that apply under every theme.
struct ThemeEditsLine: View {
    let editor: ConfigurationEditor
    let theme: ThemeChoice
    /// False while a linked theme is tried: its edits aren't the selected theme's.
    let showsEdits: Bool
    @State private var showsChanges = false
    @State private var reverting = false
    @State private var naming: SaveAsTheme?

    private var gallery: ThemeGallery { editor.gallery }
    private var edits: ThemeEdits { gallery.edits }
    private var name: String { theme.manifest.name }

    var body: some View {
        let listed = showsEdits && !(edits.changes.isEmpty && edits.everyTheme.isEmpty)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Customize theme “\(name)”").font(.system(size: 14, weight: .semibold))
                    Text("Your changes stay with \(name). Other themes keep their own look.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if listed {
                    Text(([edits.changes.isEmpty ? nil : count(edits.changes.count),
                           edits.everyTheme.isEmpty ? nil : "\(edits.everyTheme.count) for every theme"] as [String?])
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Button(showsChanges ? "Hide Changes" : "Show Changes") { withAnimation(.snappy) { showsChanges.toggle() } }
                        .buttonStyle(.link)
                }
                if showsEdits, !edits.changes.isEmpty {
                    Button("Save as Theme…") { naming = SaveAsTheme(theme: theme, selecting: true) }
                    Button("Revert to \(name)…") { reverting = true }
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            if listed, showsChanges {
                VStack(alignment: .leading, spacing: 0) {
                    if !edits.changes.isEmpty {
                        ThemeEditList(store: editor.store, changes: edits.changes, theme: name) { change in
                            if let edit = edits.removal(of: [change]) { editor.change(edit, everyBar: editor.themeChangesEveryBar) }
                        } actions: { change in
                            Button("Apply to Every Theme") {
                                do {
                                    editor.change(try edits.applyingToEveryTheme(change, themes: gallery.choices, store: editor.store.configurationStore),
                                                  everyBar: editor.themeChangesEveryBar)
                                } catch { editor.error = errorMessage(error) }
                            }
                        }
                    }
                    if !edits.everyTheme.isEmpty {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("For every theme").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                Text("Your configuration sets these outside any theme, so every theme uses them.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Keep All with \(name) Only") {
                                editor.change(edits.keepingWithTheme(edits.everyTheme, theme: name), everyBar: editor.themeChangesEveryBar)
                            }
                        }
                        .padding(.top, 12)
                        ThemeEditList(store: editor.store, changes: edits.everyTheme, theme: name) { change in
                            editor.change(change.removal, everyBar: editor.themeChangesEveryBar)
                        } actions: { change in
                            Button("Keep with \(name) Only") {
                                editor.change(edits.keepingWithTheme([change], theme: name), everyBar: editor.themeChangesEveryBar)
                            }
                        }
                    }
                }
                .font(.system(size: 12))
                .controlSize(.small)
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.bottom, 10)
                .settingsCard()
            }
        }
        .sheet(isPresented: $reverting) {
            RevertThemeSheet(edits: edits, theme: name) {
                reverting = false
                naming = SaveAsTheme(theme: theme, selecting: false)
            } revert: {
                reverting = false
                if let edit = edits.revertEdit { editor.change(edit, everyBar: editor.themeChangesEveryBar) }
            }
        }
        .sheet(item: $naming) { saving in
            SaveAsThemeSheet(gallery: gallery, saving: saving, everyBar: editor.themeChangesEveryBar) { naming = nil }
        }
    }

    private func count(_ number: Int, of noun: String = "change") -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}

/// Each edit under its section: its value, the theme's own value, a revert arrow and `actions`.
private struct ThemeEditList<Actions: View>: View {
    let store: BarStore
    let changes: [ThemeEdit]
    let theme: String
    let revert: (ThemeEdit) -> Void
    @ViewBuilder let actions: (ThemeEdit) -> Actions

    var body: some View {
        let sections = changes.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        let tokens = store.themeTokenColors
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
            ForEach(sections, id: \.self) { section in
                Text(section)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 9)
                    .padding(.bottom, 2)
                    .gridCellColumns(4)
                ForEach(changes.filter { $0.section == section }) { change in
                    GridRow {
                        Text(change.title).lineLimit(1).truncationMode(.middle).help(change.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ThemeEditValue(value: change.value, tokens: tokens).frame(width: 170, alignment: .leading)
                        HStack(spacing: 4) {
                            if let value = change.themeValue {
                                Text("\(theme):")
                                ThemeEditValue(value: value, tokens: tokens).layoutPriority(1)
                            }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 200, alignment: .leading)
                        HStack(spacing: 0) {
                            Button {
                                revert(change)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Revert \(change.title.lowercased())")
                            .accessibilityLabel("Revert \(change.title)")
                            Menu {
                                actions(change)
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 22, height: 22)
                            .accessibilityLabel("More for \(change.title)")
                        }
                    }
                    .frame(minHeight: 26)
                }
            }
        }
        .font(.system(size: 13))
    }
}

/// A value in one line: a theme color as its swatches and name, another color as each side's swatch and hex, anything
/// else as short text. The whole value is in its help.
private struct ThemeEditValue: View {
    let value: ConfigurationValue
    let tokens: [ThemeTokenColor]

    var body: some View {
        HStack(spacing: 5) {
            if let sides = colorSides(value) {
                if case let .string(text) = value, text.hasPrefix("@token.") {
                    HStack(spacing: 2) { ForEach(Array(sides.enumerated()), id: \.offset) { swatch($1) } }
                    Text(tokens.first { $0.name == text.dropFirst(7) }?.title ?? String(text.dropFirst(7)))
                } else {
                    ForEach(Array(sides.enumerated()), id: \.offset) { _, rgba in
                        swatch(rgba)
                        Text(String(format: "#%06X", rgba >> 8)).monospacedDigit()
                    }
                }
            } else {
                Text(text)
            }
        }
        .lineLimit(1)
        .help(value.sourceDescription)
    }

    private func swatch(_ rgba: UInt32) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(HexColor(rgba).color).frame(width: 12, height: 12)
            .overlay(RoundedRectangle(cornerRadius: 3).pixelBorder(.primary.opacity(0.15)))
            .accessibilityHidden(true)
    }

    /// A color's light and dark sides, one when they match, with theme colors resolved.
    private func colorSides(_ value: ConfigurationValue) -> [UInt32]? {
        func color(_ side: ConfigurationValue) -> HexColor? {
            if case let .string(text) = side, text.hasPrefix("@token.") { return tokens.first { $0.name == text.dropFirst(7) }?.color }
            return try? side.decoded(HexColor.self)
        }
        if case let .object(pair) = value, Set(pair.keys) == ["light", "dark"],
           let light = color(pair["light"]!)?.light, let dark = color(pair["dark"]!)?.dark {
            return light == dark ? [light] : [light, dark]
        }
        return color(value).map { $0.light == $0.dark ? [$0.light] : [$0.light, $0.dark] }
    }

    private var text: String {
        switch value {
        case .null: "None"
        case .object where value.isGradient: "Gradient"
        case .object, .array: "Custom"
        default: value.sourceDescription
        }
    }
}

/// Asks before removing a theme's edits, and offers to keep them as a theme of their own.
private struct RevertThemeSheet: View {
    let edits: ThemeEdits
    let theme: String
    let saveFirst: () -> Void
    let revert: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sections = edits.changes.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        VStack(alignment: .leading, spacing: 12) {
            Text("Revert \(theme)?").font(.headline)
            Text("This removes your \(edits.changes.count) \(edits.changes.count == 1 ? "change" : "changes") to \(theme):")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(sections, id: \.self) { section in
                    GridRow {
                        Text(section).foregroundStyle(.secondary).fontWeight(.semibold)
                        Text(edits.changes.filter { $0.section == section }.map(\.title).joined(separator: ", "))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).pixelBorder(SettingsPalette.groupBorder))
            Text((edits.everyTheme.isEmpty ? "" : "\(edits.everyTheme.map(\.title).formatted(.list(type: .and))) "
                  + "\(edits.everyTheme.count == 1 ? "applies" : "apply") to every theme, so \(edits.everyTheme.count == 1 ? "it stays" : "they stay"). ")
                 + "You can undo this.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Save as Theme…", action: saveFirst)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Revert", action: revert).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct SaveAsTheme: Identifiable {
    let theme: ThemeChoice
    /// Whether the new theme is selected; otherwise the theme it's based on stays selected without its edits.
    let selecting: Bool
    var id: Bool { selecting }
}

private struct SaveAsThemeSheet: View {
    let gallery: ThemeGallery
    let saving: SaveAsTheme
    let everyBar: Bool
    let close: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as Theme").font(.headline)
            TextField("Name", text: $name).frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await gallery.save(saving.theme, as: name, everyBar: everyBar, selecting: saving.selecting) }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(packageSlug(name).isEmpty)
            }
        }
        .padding(24)
        .onAppear {
            let manifest = saving.theme.manifest
            name = saving.theme.isBundled || manifest.repository != nil ? "My \(manifest.name)" : manifest.name
        }
    }
}
