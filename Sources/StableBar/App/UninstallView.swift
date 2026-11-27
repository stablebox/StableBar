import AppKit
import SwiftUI

/// Settings › General › Uninstall: puts back what StableBar changed on this Mac, removes it and quits.
struct UninstallSettings: View {
    let store: BarStore
    @State private var uninstall: UninstallController

    init(store: BarStore) {
        self.store = store
        _uninstall = State(initialValue: UninstallController(store: store))
    }

    var body: some View {
        SettingRow(title: "Uninstall StableBar",
                   hint: UninstallSystem.isAvailable ? "Put back the macOS settings StableBar changed, remove what it added, then move it to the Trash."
                       : "Uninstall works from StableBar.app.") {
            Button("Uninstall…") { uninstall.open() }
                .disabled(!UninstallSystem.isAvailable)
        }
        // The sheet reads the flow from the controller as it draws: a value captured for its content would be the one
        // from before the button read this Mac.
        .sheet(isPresented: Binding(get: { uninstall.flow.isPresented }, set: { if !$0 { uninstall.send(.cancel) } })) {
            UninstallSheet(controller: uninstall)
        }
    }
}

/// Settings' uninstall: reads this Mac when the sheet opens and performs what `UninstallFlow` decides.
@MainActor @Observable
final class UninstallController {
    private(set) var flow: UninstallFlow
    @ObservationIgnored private weak var store: BarStore?

    init(store: BarStore?, flow: UninstallFlow = UninstallFlow()) {
        self.store = store
        self.flow = flow
    }

    func open() {
        send(.open(UninstallSystem.snapshot()))
    }

    func send(_ event: UninstallFlow.Event) {
        for effect in flow.handle(event) { perform(effect) }
    }

    private func perform(_ effect: UninstallFlow.Effect) {
        switch effect {
        case let .run(steps):
            // Stopped widgets and update checks can't write back the caches and preferences the steps remove.
            store?.update?.stop()
            store?.stop()
            Task { send(.ranSteps(await Uninstall.run(steps, perform: UninstallSystem.perform))) }
        case .startFinish:
            do {
                try UninstallSystem.finishAfterQuit()
                send(.startedFinish(failure: nil))
            } catch {
                send(.startedFinish(failure: errorMessage(error)))
            }
        case .quit:
            Self.endSheets(of: NSApp.windows)
            QuitLog.quit(.uninstall)
        }
    }

    /// AppKit won't quit while a window has a sheet attached, and only beeps, so the sheet that asks to quit ends first.
    static func endSheets(of windows: [NSWindow]) {
        for window in windows {
            guard let sheet = window.attachedSheet else { continue }
            window.endSheet(sheet)
            sheet.orderOut(nil)
        }
    }
}

struct UninstallSheet: View {
    let controller: UninstallController
    @State private var options: UninstallOptions

    init(controller: UninstallController) {
        self.controller = controller
        _options = State(initialValue: UninstallOptions(controller.flow.snapshot))
    }

    private var snapshot: UninstallSnapshot { controller.flow.snapshot }

    var body: some View {
        let phase = controller.flow.phase
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if case let .finished(outcomes, finishing) = phase { finished(outcomes, finishing: finishing) } else { confirmation }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            HStack {
                if case .running = phase { ProgressView().controlSize(.small) }
                Spacer()
                if case .finished = phase {
                    Button("Quit StableBar") { controller.send(.quit) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { controller.send(.cancel) }.keyboardShortcut(.cancelAction).disabled(phase != .confirming)
                    Button("Uninstall", role: .destructive) { controller.send(.confirm(options)) }.disabled(phase != .confirming)
                }
            }
            .padding(12)
        }
        .frame(width: 520)
        .background(SettingsPalette.background)
        .interactiveDismissDisabled(phase != .confirming)
    }

    @ViewBuilder private var confirmation: some View {
        Text("Uninstall StableBar?").font(.system(size: 17, weight: .semibold))
        Text(snapshot.homebrew
             ? "StableBar puts back what it changed on this Mac and removes what it added, then you quit it. Homebrew installed the app, so finish with \(UninstallSnapshot.homebrewCommand)."
             : "StableBar puts back what it changed on this Mac and removes what it added, then quits and moves itself to the Trash.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(listedSteps, id: \.self) { step in
                Label(step.title, systemImage: "checkmark").labelStyle(UninstallStepLabelStyle())
            }
        }
        if snapshot.menuBarHides {
            Toggle(isOn: $options.showsMenuBar) {
                choice("Turn off the macOS menu bar’s auto-hide", snapshot.turnedOnMenuBarAutoHide
                       ? "StableBar turned it on so the bar could take the menu bar’s place."
                       : "It’s on, but StableBar didn’t turn it on, so it stays unless you check this.")
            }
        }
        if let configuration = snapshot.configuration {
            Toggle(isOn: $options.removesConfiguration) {
                choice("Also move \(configuration.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) to the Trash",
                       "Your configuration, scripts and packages. Keep it to set up StableBar the same way later.")
            }
        }
        if snapshot.asksForPassword {
            Text("macOS asks for an administrator password to remove the \(CommandLineTool.name) command.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The steps the toggles below don't already show.
    private var listedSteps: [UninstallStep] {
        snapshot.steps(options).filter { step in
            switch step {
            case .showMenuBar, .configuration: false
            default: true
            }
        }
    }

    private func choice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func finished(_ outcomes: [UninstallOutcome], finishing: Bool) -> some View {
        let failed = outcomes.filter { $0.error != nil }
        Text(failed.isEmpty ? "Quit StableBar to finish uninstalling" : "Some steps still need you")
            .font(.system(size: 17, weight: .semibold))
        ForEach(failed, id: \.step) { outcome in
            VStack(alignment: .leading, spacing: 3) {
                Label(outcome.step.title, systemImage: "exclamationmark.triangle.fill").labelStyle(UninstallStepLabelStyle(warning: true))
                Text("\(outcome.error ?? "") \(outcome.step.fix)")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
        if finishing {
            Text(snapshot.homebrew
                 ? "Once StableBar has quit, it resets its permissions and deletes its caches and preferences."
                 : "Once StableBar has quit, it resets its permissions, deletes its caches and preferences and moves itself to the Trash.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if snapshot.homebrew {
            Text("Homebrew installed StableBar. To remove the app, run this in Terminal after quitting:")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(UninstallSnapshot.homebrewCommand)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UninstallSnapshot.homebrewCommand, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct UninstallStepLabelStyle: LabelStyle {
    var warning = false

    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? SettingsPalette.warning : .secondary)
                .frame(width: 14)
            configuration.title
        }
    }
}
