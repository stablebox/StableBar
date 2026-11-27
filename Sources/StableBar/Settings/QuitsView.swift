import AppKit
import SwiftUI

/// Settings › Status › Unexpected quits: the quits another app or macOS asked for in the last 30 days, outside a log out,
/// restart or shut down, with the process that asked.
struct QuitsView: View {
    let crashes: CrashReports
    @State private var copiedID: QuitRecord.ID?

    var body: some View {
        Form {
            Section {
                if crashes.quits.isEmpty {
                    Label("No unexpected quits in the last 30 days", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(SettingsPalette.success)
                }
            } header: {
                SettingsSectionTitle("Unexpected quits")
            } footer: {
                Text("StableBar notes each time another app or macOS asks it to quit without logging out, restarting or shutting down, and which process asked. It keeps them on this Mac for 30 days and sends nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(crashes.quits) { quit in
                Section {
                    LabeledContent("Asked by", value: quit.sender.map { $0.name ?? "Process \($0.pid)" } ?? "Not known")
                    if let sender = quit.sender {
                        LabeledContent("Process") {
                            Text([sender.bundleID, "pid \(sender.pid)"].compactMap { $0 }.joined(separator: " · ")).textSelection(.enabled)
                        }
                        if let path = sender.path {
                            LabeledContent("Path") {
                                Text(path).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if let parent = sender.parent { LabeledContent("Started by", value: parent) }
                    }
                    LabeledContent("Your Mac", value: quit.conditions.isEmpty ? "awake" : quit.conditions.joined(separator: ", "))
                    HStack {
                        Button("Copy details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CrashReport.redacted(quit.summary()), forType: .string)
                            copiedID = quit.id
                        }
                        Spacer()
                        Button("Dismiss") { crashes.dismiss(quit) }
                    }
                    if copiedID == quit.id {
                        Text("Details copied. Paste them into a GitHub issue.").font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    SettingsSectionTitle("\(quit.date.formatted(date: .abbreviated, time: .shortened)) · StableBar \(quit.version ?? "development build")")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await crashes.refresh() }
    }
}
