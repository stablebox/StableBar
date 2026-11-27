import AppKit
import Security
import os

/// Why StableBar quit: chosen in StableBar, or asked for by another process through a Quit Apple Event.
struct QuitRecord: Codable, Equatable, Identifiable, Sendable {
    enum Cause: String, Codable, Sendable {
        /// Quit StableBar in the menu-bar icon's or the bar's menu.
        case menu
        /// `StableBar --quit`.
        case command
        /// Another bar already answers this configuration's commands.
        case controlTaken
        /// Sparkle relaunches StableBar to install an update; its installer asks with a Quit Apple Event.
        case update
        /// Uninstall quits once its steps are done.
        case uninstall
        /// Move to Applications relaunches the copy in Applications.
        case applicationMove
        /// A Quit Apple Event that StableBar didn't ask for, such as one from loginwindow, Activity Monitor or `osascript`.
        case appleEvent
        /// None of the above.
        case unknown
    }

    /// The process that sent the Quit Apple Event, read while StableBar handles it.
    struct Sender: Codable, Equatable, Sendable {
        var pid: Int32
        var name: String?
        /// Its bundle identifier, or the code-signing identifier of a tool without a bundle.
        var bundleID: String?
        var path: String?
        /// Its parent, as `name (pid)`, which tells who ran a tool such as `osascript`.
        var parent: String?
    }

    /// The quit reasons that end the session.
    static let sessionEndings: Set<String> = ["log out", "restart", "shut down"]

    var date: Date
    var cause: Cause
    var sender: Sender?
    /// The event's quit reason: `log out`, `restart` or `shut down`, any other as its four-character code, or `unreadable`.
    var reason: String?
    /// What kept widgets paused at the time, such as `system asleep`.
    var conditions: [String] = []
    var version: String?
    /// The name of the file the record was read from, which tells two equal records apart.
    var file: String?

    private enum CodingKeys: String, CodingKey { case date, cause, sender, reason, conditions, version }

    var id: String { file ?? String(date.timeIntervalSinceReferenceDate) }

    /// A quit nobody chose in StableBar and macOS didn't send to log out, restart or shut down.
    var isUnexpected: Bool {
        switch cause {
        case .appleEvent: !Self.sessionEndings.contains(reason ?? "")
        case .unknown: true
        default: false
        }
    }

    /// One line for a bug report and the unified log.
    func summary(timeZone: TimeZone = .current) -> String {
        let date = date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone))
        let what = switch cause {
        case .menu: "quit from a StableBar menu"
        case .command: "quit by StableBar --quit"
        case .controlTaken: "quit at launch, another StableBar controls this configuration"
        case .update: "quit to install an update"
        case .uninstall: "quit to finish uninstalling"
        case .applicationMove: "quit to relaunch from Applications"
        case .appleEvent: "quit by a Quit Apple Event"
        case .unknown: "quit for a reason StableBar didn't record"
        }
        var line = "\(date)\(version.map { ", StableBar \($0)" } ?? ""): \(what)"
        if let sender {
            let details = [sender.bundleID, "pid \(sender.pid)", sender.path, sender.parent.map { "parent \($0)" }].compactMap { $0 }
            line += " from \(sender.name ?? "an unknown process") (\(details.joined(separator: ", ")))"
        } else if cause == .appleEvent {
            line += " from an unknown sender"
        }
        if let reason { line += Self.sessionEndings.contains(reason) ? " to \(reason)" : " with quit reason \(reason)" }
        if !conditions.isEmpty { line += " while \(conditions.joined(separator: ", "))" }
        return line
    }

    /// The record of a quit about to happen. `intent` is the cause StableBar marked before quitting, and `quit` the
    /// Quit Apple Event being handled, if any.
    static func make(date: Date, intent: Cause?, quit: QuitEvent?, pauses: Set<PauseReason>, version: String?,
                     sender: (QuitEvent) -> Sender? = { Sender(event: $0) }) -> QuitRecord {
        QuitRecord(date: date, cause: intent ?? (quit == nil ? .unknown : .appleEvent),
                   sender: quit.flatMap(sender), reason: quit?.reason,
                   conditions: PauseReason.allCases.filter(pauses.contains).map(\.condition), version: version)
    }
}

/// The parts of a Quit Apple Event that say who sent it and why.
struct QuitEvent: Equatable, Sendable {
    var senderPID: pid_t?
    /// The sender's audit token, which names the process even after its pid is reused.
    var auditToken: Data?
    var reason: String?

    init?(_ event: NSAppleEventDescriptor) {
        self.init(eventClass: event.eventClass, eventID: event.eventID, parameter: event.paramDescriptor(forKeyword:),
                  attribute: event.attributeDescriptor(forKeyword:))
    }

    /// The Apple Event Manager adds the sender's pid and audit token only to an event it delivers, so tests pass
    /// parameters and attributes this way.
    init?(eventClass: AEEventClass, eventID: AEEventID, parameter: (AEKeyword) -> NSAppleEventDescriptor? = { _ in nil },
          attribute: (AEKeyword) -> NSAppleEventDescriptor?) {
        guard eventClass == AEEventClass(kCoreEventClass), eventID == AEEventID(kAEQuitApplication) else { return nil }
        let pid = attribute(AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        senderPID = pid > 0 ? pid : nil
        auditToken = attribute(AEKeyword(keySenderAuditTokenAttr))?.data.nonEmpty
        // AERegistry.h documents the reason as a parameter, while Apple's sample code reads an attribute.
        reason = (parameter(AEKeyword(kAEQuitReason)) ?? attribute(AEKeyword(kAEQuitReason))).map(Self.reason(of:))
    }

    /// Reads only an enumerated or type code: NSAppleEventDescriptor coerces anything else into a made-up one.
    static func reason(of descriptor: NSAppleEventDescriptor) -> String {
        let code = switch descriptor.descriptorType {
        case DescType(typeEnumerated): descriptor.enumCodeValue
        case DescType(typeType): descriptor.typeCodeValue
        default: OSType(0)
        }
        return code == 0 ? "unreadable" : reason(code)
    }

    /// The reasons loginwindow sends, in words, and any other as its four-character code.
    static func reason(_ code: OSType) -> String {
        switch code {
        case OSType(kAELogOut), OSType(kAEReallyLogOut): "log out"
        case OSType(kAEShowRestartDialog), OSType(kAERestart): "restart"
        case OSType(kAEShowShutdownDialog), OSType(kAEShutDown): "shut down"
        default:
            "'" + String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self) + "'"
        }
    }
}

private extension Data {
    var nonEmpty: Data? { isEmpty ? nil : self }
}

extension QuitRecord.Sender {
    /// The event's sender, or nil when the event names no pid.
    init?(event: QuitEvent, handledAt date: Date = Date()) {
        guard let pid = event.senderPID else { return nil }
        self.init(pid: pid, auditToken: event.auditToken, handledAt: date)
    }

    /// Reads the sender with public calls. Code signing finds the process by its audit token, which fails once it has
    /// exited, and then the pid may already be another process's, so only the pid is kept. Without a token, a process
    /// that started after `date` holds a reused pid.
    init(pid: pid_t, auditToken: Data?, handledAt date: Date) {
        self.pid = pid
        let signed = auditToken.flatMap(SignedProcess.init(auditToken:))
        let process = KernelProcess(pid: pid)
        if auditToken != nil {
            guard signed != nil else { return }
        } else {
            guard process.map({ $0.started <= date }) == true else { return }
        }
        let app = NSRunningApplication(processIdentifier: pid)
        bundleID = app?.bundleIdentifier ?? signed?.identifier
        path = signed?.path ?? app?.executableURL?.path
        name = app?.localizedName ?? process?.name ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let parent = process?.parent, parent > 0 {
            let parentName = NSRunningApplication(processIdentifier: parent)?.localizedName ?? KernelProcess(pid: parent)?.name
            self.parent = "\(parentName ?? "unknown") (\(parent))"
        }
    }
}

/// What code signing says about the process an audit token names.
struct SignedProcess {
    var path: String?
    var identifier: String?

    init?(auditToken: Data) {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        if SecCodeCopyPath(staticCode, [], &url) == errSecSuccess { path = (url as URL?)?.path }
        var information: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess {
            identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
        }
    }
}

/// A process as `sysctl` describes it.
struct KernelProcess {
    /// Its command name, cut to 16 characters.
    var name: String
    var parent: pid_t
    var started: Date

    init?(pid: pid_t) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        parent = info.kp_eproc.e_ppid
        let start = info.kp_proc.p_un.__p_starttime
        started = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}

extension PauseReason {
    var condition: String {
        switch self {
        case .systemAsleep: "system asleep"
        case .displaysAsleep: "displays asleep"
        case .screenLocked: "screen locked"
        case .sessionInactive: "session inactive"
        }
    }
}

/// StableBar's last quits, one file each, so bars that quit at once, as at log out, never write over each other.
struct QuitHistory: Sendable {
    static let limit = 10
    static let window: TimeInterval = 30 * 24 * 60 * 60
    static let standard = QuitHistory(directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/StableBar/Quits", directoryHint: .isDirectory))
    /// Records nothing and lists nothing.
    static let none = QuitHistory(directory: nil)

    let directory: URL?

    /// The quits of the last 30 days, newest first. A file this build can't read, such as one a newer release wrote, is
    /// left out and left alone.
    func records(now: Date = Date()) -> [QuitRecord] {
        stored().map(\.record).filter { now.timeIntervalSince($0.date) < Self.window }.sorted(by: Self.newestFirst)
    }

    /// Writes `record` to a file of its own, then removes the quits past 30 days and beyond the newest ten.
    func append(_ record: QuitRecord, now: Date = Date()) {
        guard let directory, let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int64(record.date.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
        try? data.write(to: directory.appending(path: name), options: .atomic)
        let kept = stored().sorted { Self.newestFirst($0.record, $1.record) }
        for (index, entry) in kept.enumerated() where index >= Self.limit || now.timeIntervalSince(entry.record.date) >= Self.window {
            try? FileManager.default.removeItem(at: entry.file)
        }
    }

    /// Deletes the file `record` was read from, and no other.
    func remove(_ record: QuitRecord) {
        guard let directory, let file = record.file, !file.contains("/") else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: file))
    }

    /// Newest first; the file name orders quits of the same moment the same way every time.
    private static func newestFirst(_ first: QuitRecord, _ second: QuitRecord) -> Bool {
        first.date != second.date ? first.date > second.date : (first.file ?? "") > (second.file ?? "")
    }

    private func stored() -> [(file: URL, record: QuitRecord)] {
        guard let directory else { return [] }
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: .skipsHiddenFiles)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard var record = (try? Data(contentsOf: file)).flatMap({ try? decoder.decode(QuitRecord.self, from: $0) }) else { return nil }
            record.file = file.lastPathComponent
            return (file, record)
        }
    }
}

/// Records why StableBar quits, in the unified log and the quit history.
@MainActor
enum QuitLog {
    nonisolated static let logger = Logger(subsystem: "org.stablebar.app", category: "quit")
    private(set) static var intent: QuitRecord.Cause?

    /// Quits, recording `cause` instead of reading it from an Apple Event. AppKit can decline, such as while a sheet
    /// is open, and then returns, so the cause doesn't outlive the attempt.
    static func quit(_ cause: QuitRecord.Cause, terminate: () -> Void = { NSApp.terminate(nil) }) {
        intent = cause
        defer { intent = nil }
        terminate()
    }

    /// Marks the cause of a quit that something else, such as Sparkle's installer, is about to ask for.
    static func expect(_ cause: QuitRecord.Cause) { intent = cause }

    /// Forgets `cause` once what was to quit gave up.
    static func forget(_ cause: QuitRecord.Cause) {
        if intent == cause { intent = nil }
    }

    /// Called from `applicationShouldTerminate`, while AppKit still handles the Quit Apple Event that asked for it.
    @discardableResult
    static func recordQuit(pauses: Set<PauseReason>, history: QuitHistory,
                           event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent,
                           sender: (QuitEvent) -> QuitRecord.Sender? = { QuitRecord.Sender(event: $0) }) -> QuitRecord {
        let record = QuitRecord.make(date: Date(), intent: intent, quit: event.flatMap(QuitEvent.init), pauses: pauses,
                                     version: AppVersion().version, sender: sender)
        intent = nil
        let summary = logLine(record)
        logger.log(level: record.isUnexpected ? .error : .default, "\(summary, privacy: .public)")
        history.append(record)
        return record
    }

    /// The log is public, so home folders become `~` as in bug reports.
    nonisolated static func logLine(_ record: QuitRecord) -> String { CrashReport.redacted(record.summary()) }

    /// Notes the previous quit at launch, so the unified log shows how the last run ended next to this one starting.
    static func logLaunch(history: QuitHistory) {
        guard let last = history.records().first else { return }
        let summary = logLine(last)
        logger.notice("Launched; last recorded quit: \(summary, privacy: .public)")
    }
}
