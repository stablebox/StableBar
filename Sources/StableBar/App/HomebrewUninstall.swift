import AppKit
import CoreServices

/// What the Homebrew cask's `uninstall` script runs, so `brew uninstall --cask stablebar` undoes the same changes as
/// Settings › Uninstall. Homebrew also runs that script when it upgrades or reinstalls StableBar, and doesn't tell the
/// script which, so the steps wait until `brew` has exited and run only when StableBar is no longer installed.
@MainActor
enum HomebrewUninstall {
    /// Names the folder of the copy that waits for `brew`, so only that folder is ever deleted.
    nonisolated static let copyFolderPrefix = "StableBar uninstall "

    /// `--homebrew-uninstall`: runs while the app is still in place and `brew` waits for it, so it only starts the
    /// copy that waits. It never fails `brew`: when it can't start that copy, it says how to finish by hand.
    static func start() -> Int32 {
        let app = Bundle.main.bundleURL
        guard getuid() != 0, app.pathExtension == "app" else { return 0 }
        var made: URL?
        do {
            // Not in a temporary folder: Launch Services doesn't look there, so tccutil wouldn't find StableBar.
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = caches.appending(path: copyFolderPrefix + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            made = folder
            // The steps need a whole app: Open at login and the preferences belong to its bundle, and Homebrew is
            // about to delete this one.
            let copy = folder.appending(path: app.lastPathComponent, directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: app, to: copy)
            removeQuarantine(copy)
            guard let executable = Bundle(url: copy)?.executablePath else { throw CommandFailure(message: "The copy has no executable.") }
            // Homebrew deletes the preferences file when zapping, before StableBar could read this record.
            let menuBar = MenuBarAutoHide.turnedOnByStableBar() ? ["--show-menu-bar"] : []
            try spawnDetached(executable, arguments: ["--finish-homebrew-uninstall", String(getppid()), app.path] + menuBar)
            print("Once Homebrew is done, StableBar undoes what it changed on this Mac, unless Homebrew installs it again.")
        } catch {
            if let made { try? FileManager.default.removeItem(at: made) }
            print("StableBar couldn’t start undoing what it changed on this Mac: \(errorMessage(error))")
            print("See https://github.com/stablebox/StableBar/blob/main/docs/getting-started.md#uninstall to undo it by hand.")
        }
        return 0
    }

    /// `--finish-homebrew-uninstall [PID] APP [--show-menu-bar]`: with `brew`'s process ID, waits for it to exit, then
    /// opens this copy as an app without one. That copy does what Settings › Uninstall does, except moving the app,
    /// which Homebrew removed, and an alert lists any step that failed.
    static func finish(after brew: pid_t?, app: URL, showsMenuBar: Bool) async -> Int32 {
        if let brew { _ = try? await Uninstall.waitForQuit(every: .milliseconds(500)) { kill(brew, 0) == 0 } }
        guard !isInstalled(app) else {
            removeCopy()
            return 0
        }
        // Opened by Launch Services, the copy controls System Events, to turn off auto-hide, with StableBar's own
        // permission. Started from brew, it would make macOS ask whether the terminal may.
        if brew != nil, await openAsApp(["--finish-homebrew-uninstall", app.path] + (showsMenuBar ? ["--show-menu-bar"] : [])) {
            return 0
        }
        // tccutil looks StableBar up in Launch Services, which forgot it once Homebrew deleted the app.
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        var snapshot = UninstallSystem.snapshot()
        snapshot.app = nil
        var options = UninstallOptions(snapshot)
        options.showsMenuBar = options.showsMenuBar || showsMenuBar
        let steps = snapshot.steps(options)
        let outcomes = await Uninstall.run(steps, perform: UninstallSystem.perform)
        removeCopy()
        // Homebrew removed the app, so the alert lists every step left to do by hand, not just the quit.
        return UninstallSystem.report(outcomes + Uninstall.notRun(steps, after: outcomes))
    }

    /// Whether StableBar is still installed once `brew` is done, as after an upgrade, a reinstall or a failed uninstall.
    nonisolated static func isInstalled(_ app: URL, caskrooms: [URL] = UninstallSnapshot.caskrooms) -> Bool {
        FileManager.default.fileExists(atPath: app.path) || UninstallSnapshot.installedByHomebrew(caskrooms: caskrooms)
    }

    /// The folder `start` made for this copy, or nil when StableBar runs from anywhere else.
    nonisolated static func copyFolder(of bundle: URL) -> URL? {
        let folder = bundle.deletingLastPathComponent()
        return folder.lastPathComponent.hasPrefix(copyFolderPrefix) ? folder : nil
    }

    private static func openAsApp(_ arguments: [String]) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        return (try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)) != nil
    }

    /// The copy keeps the quarantine of Homebrew's download, which can make macOS ask before opening it.
    private static func removeQuarantine(_ bundle: URL) {
        let contents = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in [bundle] + contents { removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    private static func removeCopy() {
        guard let folder = copyFolder(of: Bundle.main.bundleURL) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
