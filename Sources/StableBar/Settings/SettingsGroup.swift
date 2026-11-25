import SwiftUI

struct SettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    let reset: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, reset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.reset = reset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                heading
                Spacer()
                if let reset {
                    Button("Reset", action: reset)
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                        .accessibilityLabel("Reset \(title)")
                }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .labeledContentStyle(GroupRowStyle())
                .padding(.top, -1)
                .settingsCard()
        }
        .padding(.top, 22)
        .id(title)
    }

    private var heading: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
            if let detail { Text("· \(detail)").font(.system(size: 11.5)) }
        }
        .foregroundStyle(.secondary)
    }
}

struct GroupRowStyle: LabeledContentStyle {
    func makeBody(configuration: LabeledContentStyleConfiguration) -> some View {
        HStack(spacing: 10) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 46)
        .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
    }
}

extension View {
    func groupRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
    }

    /// The card a group's rows sit in, clipped to its rounded corners.
    func settingsCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 10))
            .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).pixelBorder(SettingsPalette.groupBorder))
    }
}
