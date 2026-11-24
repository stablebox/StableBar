import SwiftUI

@MainActor
struct WidgetsLookSection {
    let style: StyleFields
    let fontFamilies: [String]

    var paths: [String] { [style.path] }

    @ViewBuilder var rows: some View {
        LightDarkHeader()
        style.color("Text color", "foreground")
        style.color("Background", "background")
        style.hoverBackground("Hover background")
        style.color("Border color", "borderColor")
        style.color("Shadow color", "shadowColor")
        style.color("Accent", "accent")
        style.color("Accent text color", "accentText")
        style.choice("App icons", "appIcons", choices: AppIcons.allCases.map(\.rawValue), default: AppIcons.color.rawValue)
        style.font(fontFamilies)
        style.weight()
        style.number("Text size", "fontSize", default: 13, in: 6...40, slider: true)
        style.padding(default: 10, 6)
        style.number("Corner radius", "cornerRadius", default: 14, in: 0...40, slider: true)
        style.number("Border width", "borderWidth", default: 0, in: 0...6, step: 0.5)
    }
}

struct GroupsLookSection: View {
    let editor: ConfigurationEditor
    let style: StyleFields
    let flared: Bool
    /// The space between the group's widgets when it sets none.
    let spacing: Double
    var title = "Groups"

    var paths: [String] { [style.path] }

    var body: some View {
        LookSection(title: title, editor: editor, paths: paths) { rows }
    }

    @ViewBuilder var rows: some View {
        LightDarkHeader()
        style.color("Text color", "foreground")
        style.color("Background", "background")
        style.color("Border color", "borderColor").disabled(flared)
        style.number("Border width", "borderWidth", default: 0, in: 0...6, step: 0.5,
                     hint: flared ? "A group with a flare draws no border" : nil).disabled(flared)
        style.color("Shadow color", "shadowColor")
        style.number("Corner radius", "cornerRadius", default: 0, in: 0...40, slider: true)
        style.number("Flare", "flare", default: 0, in: 0...30, slider: true, hint: "Curves the top corners outward, like the notch")
        style.number("Horizontal padding", "paddingHorizontal", default: 0, in: 0...30, slider: true)
        style.number("Vertical padding", "paddingVertical", default: 0, in: 0...20, slider: true)
        style.number("Space between widgets", "spacing", default: spacing, in: 0...30, slider: true)
    }
}

/// `style` sets popups over the widgets' look; `spacing` sets their padding and spacing, which popups don't take from
/// widgets; `bar` sets their gap below the bar.
@MainActor
struct PopupsLookSection {
    let style: StyleFields
    let spacing: StyleFields
    let bar: StyleFields
    let fontFamilies: [String]

    var paths: [String] { [style.path, "\(bar.path).popupOffset"] }

    @ViewBuilder var rows: some View {
        let padding = PopupConfiguration.defaultPadding
        LightDarkHeader()
        style.color("Text color", "foreground")
        style.color("Background", "background")
        style.color("Border color", "borderColor")
        style.color("Shadow color", "shadowColor")
        style.font(fontFamilies)
        style.weight()
        style.number("Text size", "fontSize", default: 13, in: 6...40)
        style.number("Corner radius", "cornerRadius", default: 14, in: 0...40)
        spacing.number("Horizontal padding", "paddingHorizontal", default: padding.paddingHorizontal!, in: 0...40)
        spacing.number("Vertical padding", "paddingVertical", default: padding.paddingVertical!, in: 0...40)
        spacing.number("Spacing", "spacing", default: PopupConfiguration.blockSpacing, in: 0...40,
                       hint: "Unset, a popup's blocks sit 12 apart and the items of a row, column or list 6. A value sets both.")
        bar.number("Gap below the bar", "popupOffset", default: BarSettings().popupOffset, in: 0...40,
                   hint: "Also moves tooltips and hover controls. A popup's own offset wins.")
    }
}

/// A section's rows in the bar editor, with its count of the selected theme's edits under `paths`, the `StyleFields` paths
/// the rows edit, and Reset while there are some. The Theme page shows the same `rows` in sections it opens and closes.
private struct LookSection<Content: View>: View {
    let title: String
    let editor: ConfigurationEditor
    let paths: [String]
    @ViewBuilder let content: Content

    var body: some View {
        let changes = editor.lookChanges(under: paths)
        SettingsGroup(title, detail: changeCount(changes.count), reset: editor.reset(changes, everyBar: false)) {
            content
        }
    }
}

/// "3 changes", or nil for none.
func changeCount(_ count: Int) -> String? {
    count == 0 ? nil : "\(count) \(count == 1 ? "change" : "changes")"
}

extension ConfigurationEditor {
    /// The selected theme's edits under `paths`, as the gallery last read them.
    func lookChanges(under paths: [String]) -> [ThemeEdit] {
        gallery.edits.changes.filter { change in
            paths.contains { change.path.starts(with: $0.split(separator: ".").map(String.init)) }
        }
    }

    /// Removes `changes`; nil when there are none, or while a profile is being edited, since every change then goes into
    /// that profile.
    func reset(_ changes: [ThemeEdit], everyBar: Bool) -> (() -> Void)? {
        guard editingProfile == nil, let edit = gallery.edits.removal(of: changes) else { return nil }
        return { self.change(edit, everyBar: everyBar) }
    }
}
