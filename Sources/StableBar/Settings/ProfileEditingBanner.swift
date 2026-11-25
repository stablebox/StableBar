import SwiftUI

struct ProfileEditingBanner: View {
    let editor: ConfigurationEditor

    var body: some View {
        if let name = editor.editingProfile {
            HStack(spacing: 8) {
                Image(systemName: "pencil").foregroundStyle(SettingsPalette.profile)
                Text("Editing for profile **\(name)**. What you change now applies only while it’s active.")
                Spacer()
                Button("Done") { editor.showProfile(name) }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SettingsPalette.profileSoft, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).pixelBorder(SettingsPalette.profile))
        }
    }
}

