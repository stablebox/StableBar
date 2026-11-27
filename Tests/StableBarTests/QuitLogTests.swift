import AppKit
import Foundation
import Testing
@testable import StableBar

private let date = Date(timeIntervalSince1970: 1_795_000_000)
private let utc = TimeZone(identifier: "UTC")!

private func appleEvent(_ id: AEEventID = AEEventID(kAEQuitApplication)) -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id, targetDescriptor: nil,
                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
}

private func quitEvent(sender pid: Int32? = nil, reason: OSType? = nil) -> QuitEvent? {
    let attributes = [AEKeyword(keySenderPIDAttr): pid.map { NSAppleEventDescriptor(int32: $0) },
                      AEKeyword(kAEQuitReason): reason.map { NSAppleEventDescriptor(enumCode: $0) }]
    return QuitEvent(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication)) { attributes[$0] ?? nil }
}

private let loginwindow = QuitRecord.Sender(pid: 412, name: "loginwindow", bundleID: "com.apple.loginwindow",
                                            path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                                            parent: "launchd (1)")

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "QuitLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// This process's audit token, as an Apple Event's sender would carry it.
private func ownAuditToken() throws -> Data {
    var token = audit_token_t()
    var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &token) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
    }
    try #require(result == KERN_SUCCESS)
    return Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
}

@Test func onlyAQuitAppleEventIsReadAsOne() {
    let event = appleEvent()
    event.setAttribute(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)), forKeyword: AEKeyword(kAEQuitReason))
    #expect(QuitEvent(event)?.reason == "shut down")
    #expect(QuitEvent(event)?.senderPID == nil)
    #expect(QuitEvent(appleEvent(AEEventID(kAEOpenApplication))) == nil)
}

@Test func theQuitReasonIsReadAsAParameterFirst() {
    let event = appleEvent()
    event.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)), forKeyword: AEKeyword(kAEQuitReason))
    #expect(QuitEvent(event)?.reason == "shut down")
    event.setAttribute(NSAppleEventDescriptor(enumCode: OSType(kAELogOut)), forKeyword: AEKeyword(kAEQuitReason))
    #expect(QuitEvent(event)?.reason == "shut down")
}

@Test func aQuitAppleEventRecordsItsSenderAndTheMacsState() {
    var asked: [pid_t?] = []
    let record = QuitRecord.make(date: date, intent: nil, quit: quitEvent(sender: 412), pauses: [.displaysAsleep, .systemAsleep],
                                 version: "0.19.0") { asked.append($0.senderPID); return loginwindow }
    #expect(asked == [412])
    #expect(record == QuitRecord(date: date, cause: .appleEvent, sender: loginwindow, reason: nil,
                                 conditions: ["system asleep", "displays asleep"], version: "0.19.0"))
    #expect(record.isUnexpected)
    #expect(record.summary(timeZone: utc) == "2026-11-18T11:06:40Z, StableBar 0.19.0: quit by a Quit Apple Event from loginwindow "
        + "(com.apple.loginwindow, pid 412, /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow, parent launchd (1))"
        + " while system asleep, displays asleep")
}

@Test func onlyAQuitToLogOutRestartOrShutDownIsExpected() {
    for (code, words) in [(kAELogOut, "log out"), (kAEReallyLogOut, "log out"), (kAEShowRestartDialog, "restart"), (kAERestart, "restart"),
                          (kAEShowShutdownDialog, "shut down"), (kAEShutDown, "shut down")] {
        let record = QuitRecord.make(date: date, intent: nil, quit: quitEvent(sender: 412, reason: OSType(code)), pauses: [],
                                     version: nil) { _ in loginwindow }
        #expect(record.reason == words)
        #expect(!record.isUnexpected)
        #expect(record.summary(timeZone: utc).hasSuffix("parent launchd (1)) to \(words)"))
    }
    for (code, shown) in [(OSType(kAEQuitAll), "'quia'"), (0x6162_6364, "'abcd'")] {
        let record = QuitRecord.make(date: date, intent: nil, quit: quitEvent(sender: 412, reason: code), pauses: [],
                                     version: nil) { _ in loginwindow }
        #expect(record.reason == shown)
        #expect(record.isUnexpected)
        #expect(record.summary(timeZone: utc).hasSuffix("parent launchd (1)) with quit reason \(shown)"))
    }
    #expect(QuitEvent.reason(of: NSAppleEventDescriptor.list()) == "unreadable")
    #expect(QuitEvent.reason(of: NSAppleEventDescriptor(string: "shut")) == "unreadable")
    #expect(QuitEvent.reason(of: NSAppleEventDescriptor(typeCode: OSType(kAEShutDown))) == "shut down")
}

@Test func aQuitStableBarMarkedKeepsItsCause() {
    let causes: [QuitRecord.Cause: String] = [
        .menu: "quit from a StableBar menu", .command: "quit by StableBar --quit",
        .controlTaken: "quit at launch, another StableBar controls this configuration", .update: "quit to install an update",
        .uninstall: "quit to finish uninstalling", .applicationMove: "quit to relaunch from Applications",
    ]
    for (cause, words) in causes {
        let record = QuitRecord.make(date: date, intent: cause, quit: nil, pauses: [.screenLocked], version: nil) { _ in loginwindow }
        #expect(record.cause == cause)
        #expect(record.sender == nil)
        #expect(!record.isUnexpected)
        #expect(record.summary(timeZone: utc) == "2026-11-18T11:06:40Z: \(words) while screen locked")
    }
    // Sparkle's installer quits StableBar with a Quit Apple Event of its own, whose sender stays on the record.
    let update = QuitRecord.make(date: date, intent: .update, quit: quitEvent(sender: 412), pauses: [], version: nil) { _ in loginwindow }
    #expect(update.cause == .update && update.sender == loginwindow && !update.isUnexpected)
}

@Test func aQuitWithNeitherACauseNorAQuitEventIsUnknown() {
    let record = QuitRecord.make(date: date, intent: nil, quit: nil, pauses: [], version: nil) { _ in loginwindow }
    #expect(record.cause == .unknown)
    #expect(record.isUnexpected)
    #expect(record.summary(timeZone: utc) == "2026-11-18T11:06:40Z: quit for a reason StableBar didn't record")
    let anonymous = QuitRecord.make(date: date, intent: nil, quit: quitEvent(), pauses: [], version: nil)
    #expect(anonymous.cause == .appleEvent && anonymous.sender == nil)
    #expect(anonymous.summary(timeZone: utc) == "2026-11-18T11:06:40Z: quit by a Quit Apple Event from an unknown sender")
}

@Test @MainActor func aQuitAppKitDeclinesLeavesNoCauseForALaterQuit() {
    var during: QuitRecord?
    QuitLog.quit(.command) { during = QuitLog.recordQuit(pauses: [], history: .none, event: nil) }
    #expect(during?.cause == .command)

    QuitLog.quit(.command) {}
    #expect(QuitLog.intent == nil)
    let external = QuitLog.recordQuit(pauses: [], history: .none, event: appleEvent()) { _ in loginwindow }
    #expect(external.cause == .appleEvent)

    QuitLog.expect(.update)
    QuitLog.forget(.menu)
    #expect(QuitLog.intent == .update)
    QuitLog.forget(.update)
    #expect(QuitLog.intent == nil)
}

@Test @MainActor func appDelegatesOfTestsRecordNoQuits() {
    #expect(AppDelegate(store: BarStore()).quitHistory.directory == nil)
    QuitHistory.none.append(QuitRecord(date: date, cause: .unknown))
    #expect(QuitHistory.none.records(now: date).isEmpty)
}

@Test func theLogWritesHomeFoldersAsTilde() {
    let quit = QuitRecord(date: date, cause: .appleEvent, sender: QuitRecord.Sender(pid: 7, path: "/Users/someone/bin/quitter"))
    #expect(QuitLog.logLine(quit).contains("(pid 7, ~/bin/quitter)"))
    #expect(!QuitLog.logLine(quit).contains("someone"))
}

@Test func aSenderIsReadWithPublicCallsFromItsAuditToken() throws {
    let token = try ownAuditToken()
    let signed = try #require(SignedProcess(auditToken: token))
    let path = try #require(signed.path)
    #expect(path.hasSuffix(ProcessInfo.processInfo.processName) || path.contains(".xctest") || path.hasSuffix(".app"))

    let sender = QuitRecord.Sender(pid: getpid(), auditToken: token, handledAt: Date())
    #expect(sender.path == signed.path)
    #expect(sender.name != nil)
    #expect(sender.parent?.hasSuffix("(\(getppid()))") == true)

    // A token that names no process finds nothing.
    #expect(SignedProcess(auditToken: Data(count: token.count)) == nil)
}

@Test func aSenderWhoseAuditTokenFailsKeepsOnlyItsPid() {
    // The pid is this running process's, which started long before, yet a token that doesn't resolve may mean the
    // sender exited and its pid went to another process.
    let sender = QuitRecord.Sender(pid: getpid(), auditToken: Data(count: MemoryLayout<audit_token_t>.size), handledAt: Date())
    #expect(sender == QuitRecord.Sender(pid: getpid()))
}

@Test func aSenderWithoutATokenIsTrustedOnlyIfItStartedBeforeTheQuit() {
    let process = KernelProcess(pid: getpid())
    #expect(process?.parent == getppid())
    #expect(process.map { $0.started <= Date() } == true)

    let current = QuitRecord.Sender(pid: getpid(), auditToken: nil, handledAt: Date())
    #expect(current.name != nil && current.parent != nil)
    // A process that started after the quit was handled holds a reused pid, so only the pid is kept.
    #expect(QuitRecord.Sender(pid: getpid(), auditToken: nil, handledAt: .distantPast) == QuitRecord.Sender(pid: getpid()))
    // An exited sender leaves only its pid.
    #expect(QuitRecord.Sender(pid: 99_999_999, auditToken: nil, handledAt: Date()) == QuitRecord.Sender(pid: 99_999_999))
}

@Test func quitHistoryKeepsTheLastTenOfThirtyDaysNewestFirst() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = QuitHistory(directory: folder)
    #expect(history.records(now: date).isEmpty)
    for day in (0..<12).reversed() {
        history.append(QuitRecord(date: date.addingTimeInterval(-Double(day) * 24 * 3600), cause: .menu), now: date)
    }
    let records = history.records(now: date)
    #expect(records.count == QuitHistory.limit)
    #expect(records.first?.date == date)
    #expect(records.map(\.date) == records.map(\.date).sorted(by: >))
    #expect(history.records(now: date.addingTimeInterval(25 * 24 * 3600)).count == 5)
    let files = { try FileManager.default.contentsOfDirectory(atPath: folder.path).count }
    #expect(try files() == QuitHistory.limit)

    // A file of a newer release this build can't read is skipped and kept; an expired record is pruned on the next write.
    let future = folder.appending(path: "0-future.json")
    try Data(#"{"date":0,"cause":"somethingNew","conditions":[]}"#.utf8).write(to: future)
    #expect(history.records(now: date).count == QuitHistory.limit)
    let later = date.addingTimeInterval(25 * 24 * 3600)
    history.append(QuitRecord(date: later, cause: .command), now: later)
    #expect(history.records(now: later).count == 6)
    #expect(try files() == 6 + 1)
    #expect(FileManager.default.fileExists(atPath: future.path))
}

@Test func quitsYouChoseNeverPushOutUnexpectedOnes() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = QuitHistory(directory: folder)
    let unexpected = QuitRecord(date: date.addingTimeInterval(-3600), cause: .appleEvent, reason: "quit")
    history.append(unexpected, now: date)
    for minute in (0..<(QuitHistory.limit + 2)).reversed() {
        history.append(QuitRecord(date: date.addingTimeInterval(-Double(minute) * 60), cause: .menu), now: date)
    }
    let records = history.records(now: date)
    #expect(records.filter { !$0.isUnexpected }.count == QuitHistory.limit)
    #expect(records.filter(\.isUnexpected).map(\.date) == [unexpected.date])
}

@Test func quitsWrittenAtOnceAndDismissedMeanwhileAreAllKept() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let kept = QuitRecord(date: date.addingTimeInterval(-7200), cause: .unknown)
    QuitHistory(directory: folder).append(QuitRecord(date: date.addingTimeInterval(-3600), cause: .unknown), now: date)
    QuitHistory(directory: folder).append(kept, now: date)
    let dismissed = try #require(QuitHistory(directory: folder).records(now: date).first { $0.date == date.addingTimeInterval(-3600) })
    let written = (0..<6).map { QuitRecord(date: date.addingTimeInterval(Double(-$0)), cause: .appleEvent) }
    await withTaskGroup(of: Void.self) { group in
        // Each bar has its own history pointing at the same folder.
        for record in written {
            group.addTask { QuitHistory(directory: folder).append(record, now: date) }
        }
        group.addTask { QuitHistory(directory: folder).remove(dismissed) }
    }
    let records = QuitHistory(directory: folder).records(now: date)
    #expect(Set(records.map(\.date)) == Set((written + [kept]).map(\.date)))
}

@Test @MainActor func statusListsOnlyUnexpectedQuitsAndDismissesThem() async throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = QuitHistory(directory: folder)
    let external = QuitRecord(date: date, cause: .appleEvent, sender: loginwindow, conditions: ["system asleep"])
    let older = QuitRecord(date: date.addingTimeInterval(-60), cause: .unknown)
    history.append(QuitRecord(date: date.addingTimeInterval(-300), cause: .appleEvent, sender: loginwindow, reason: "log out"), now: date)
    history.append(older, now: date)
    history.append(QuitRecord(date: date.addingTimeInterval(-30), cause: .menu), now: date)
    history.append(external, now: date)
    let defaults = try #require(UserDefaults(suiteName: "QuitLogTests-\(UUID().uuidString)"))
    let crashes = CrashReports(directories: [temporaryFolder()], defaults: defaults, quitHistory: history, now: { date })
    #expect(crashes.quits.isEmpty)
    await crashes.refresh()
    #expect(crashes.quits.map { var quit = $0; quit.file = nil; return quit } == [external, older])

    crashes.dismiss(crashes.quits[0])
    #expect(crashes.quits.map(\.date) == [older.date])
    #expect(history.records(now: date).count == 3)
    await crashes.refresh()
    #expect(crashes.quits.map(\.date) == [older.date])
}

@Test func dismissingAQuitDeletesOnlyItsOwnFile() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let history = QuitHistory(directory: folder)
    let twin = QuitRecord(date: date, cause: .unknown)
    history.append(twin, now: date)
    history.append(twin, now: date)
    let stored = history.records(now: date)
    #expect(stored.count == 2)
    #expect(Set(stored.map(\.id)).count == 2)
    #expect(stored == history.records(now: date))
    history.remove(stored[0])
    #expect(history.records(now: date).map(\.id) == [stored[1].id])
    // A record that was never read from a file names none to delete.
    history.remove(twin)
    #expect(history.records(now: date).count == 1)
}

@Test func bugReportListsRecentQuitsOnlyWhenThereAreSome() {
    var report = BugReport(version: "0.19.0", system: "27.2.1", mac: "Mac16,8", displays: [], configuration: "c", theme: "t",
                           packages: [], workspaceTool: "not used", crashes: [], live: nil)
    #expect(!report.markdown.contains("quits"))
    let quit = QuitRecord(date: date, cause: .appleEvent, sender: QuitRecord.Sender(pid: 7, path: "/Users/someone/bin/quitter"))
    report.quits = [quit.summary(timeZone: utc)]
    #expect(report.markdown.hasSuffix("""
    - Crashes in the last 30 days: none
    - Recent quits:
      - 2026-11-18T11:06:40Z: quit by a Quit Apple Event from an unknown process (pid 7, ~/bin/quitter)
    """))
}
