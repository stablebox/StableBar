import Foundation
import Testing
@testable import StableBar

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Homebrew uninstall \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func homebrewUninstallTakesNoArguments() throws {
    guard case .homebrewUninstall = try LaunchCommand(arguments: ["--homebrew-uninstall"]) else {
        Issue.record("--homebrew-uninstall wasn't parsed")
        return
    }
    for arguments in [["--homebrew-uninstall", "--yes"], ["--config", "/tmp/config.json", "--homebrew-uninstall"]] {
        #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: arguments) }
    }
}

@Test func finishHomebrewUninstallWaitsForBrewWhenGivenItsProcessID() throws {
    guard case let .finishHomebrewUninstall(brew, app, showsMenuBar) = try LaunchCommand(
        arguments: ["--finish-homebrew-uninstall", "4242", "/Applications/StableBar.app", "--show-menu-bar"]) else {
        Issue.record("--finish-homebrew-uninstall wasn't parsed")
        return
    }
    #expect(brew == 4242)
    #expect(app.path == "/Applications/StableBar.app")
    #expect(showsMenuBar)
}

@Test func finishHomebrewUninstallWithoutAProcessIDRunsAtOnce() throws {
    guard case let .finishHomebrewUninstall(brew, app, showsMenuBar) = try LaunchCommand(
        arguments: ["--finish-homebrew-uninstall", "/Users/me/Applications/StableBar.app"]) else {
        Issue.record("--finish-homebrew-uninstall wasn't parsed")
        return
    }
    #expect(brew == nil)
    #expect(app.path == "/Users/me/Applications/StableBar.app")
    #expect(!showsMenuBar)
}

@Test func finishHomebrewUninstallRejectsOtherArguments() {
    for arguments in [["--finish-homebrew-uninstall"], ["--finish-homebrew-uninstall", "4242"],
                      ["--finish-homebrew-uninstall", "0", "/Applications/StableBar.app"],
                      ["--finish-homebrew-uninstall", "-1", "/Applications/StableBar.app"],
                      ["--finish-homebrew-uninstall", "4242", "StableBar.app"],
                      ["--finish-homebrew-uninstall", "4242", "/Applications/StableBar.app", "--yes"],
                      ["--finish-homebrew-uninstall", "4242", "/Applications/StableBar.app", "/Applications/Other.app"],
                      ["--config", "/tmp/config.json", "--finish-homebrew-uninstall", "4242", "/Applications/StableBar.app"]] {
        #expect(throws: CommandFailure.self, "\(arguments)") { try LaunchCommand(arguments: arguments) }
    }
}

@Test func stableBarIsStillInstalledAfterAnUpgradeOrAReinstall() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = directory.appending(path: "Applications/StableBar.app", directoryHint: .isDirectory)
    let caskroom = directory.appending(path: "Caskroom", directoryHint: .isDirectory)
    #expect(!HomebrewUninstall.isInstalled(app, caskrooms: [caskroom]))
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    #expect(HomebrewUninstall.isInstalled(app, caskrooms: [caskroom]))
    try FileManager.default.removeItem(at: app)
    // An upgrade that failed after removing the app still leaves Homebrew's record.
    try FileManager.default.createDirectory(at: caskroom.appending(path: "stablebar"), withIntermediateDirectories: true)
    #expect(HomebrewUninstall.isInstalled(app, caskrooms: [caskroom]))
}

@Test func onlyTheCopysOwnFolderIsRemoved() {
    let copy = URL(filePath: "/Users/me/Library/Caches/\(HomebrewUninstall.copyFolderPrefix)1234/StableBar.app", directoryHint: .isDirectory)
    #expect(HomebrewUninstall.copyFolder(of: copy)?.lastPathComponent == "\(HomebrewUninstall.copyFolderPrefix)1234")
    #expect(HomebrewUninstall.copyFolder(of: URL(filePath: "/Applications/StableBar.app", directoryHint: .isDirectory)) == nil)
    #expect(HomebrewUninstall.copyFolder(of: URL(filePath: "/Users/me/Downloads/StableBar.app", directoryHint: .isDirectory)) == nil)
}

@Test func stepsAfterHomebrewLeaveTheAppToHomebrew() {
    let copy = URL(filePath: "/Users/me/Library/Caches/\(HomebrewUninstall.copyFolderPrefix)1234/StableBar.app", directoryHint: .isDirectory)
    var snapshot = UninstallSnapshot(menuBarHides: true, turnedOnMenuBarAutoHide: true, opensAtLogin: true, app: copy)
    snapshot.app = nil
    let steps = snapshot.steps(UninstallOptions(snapshot))
    #expect(steps == [.showMenuBar, .loginItem, .permissions, .files([])])
}

@Test func stepsAStableBarThatWontQuitKeptFromRunningAreListedAsNotDone() {
    let steps: [UninstallStep] = [.quit(1), .loginItem, .permissions]
    let outcomes = [UninstallOutcome(step: .quit(1), error: "StableBar is still running.")]
    #expect(Uninstall.notRun(steps, after: outcomes).map(\.step) == [.loginItem, .permissions])
    #expect(Uninstall.notRun(steps, after: outcomes).allSatisfy { $0.error != nil })
    let finished = steps.map { UninstallOutcome(step: $0, error: nil) }
    #expect(Uninstall.notRun(steps, after: finished).isEmpty)
}
