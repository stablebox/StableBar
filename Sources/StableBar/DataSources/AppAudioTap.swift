import CoreAudio
import Foundation

/// One app's sound played back by StableBar: a process tap mutes the app's processes at the source, and a private
/// aggregate device reads the tap and plays it on an output device at the app's gain.
///
/// The device waits for the app's sound: with `tapautostart`, CoreAudio starts it as the app starts playing, without
/// waiting for StableBar. It keeps running after the app stops, which keeps the output and the Mac awake, so it waits
/// again once none of the app's processes plays. The tap follows them itself: StableBar can miss a sound that starts
/// and stops between two of its looks, and the device would then run until the app's next sound ended.
final class AppAudioTap: @unchecked Sendable {
    /// The UIDs of the aggregate devices start with this. A private device is hidden from other apps but not from
    /// StableBar, so its device lists leave these out.
    static let uidPrefix = "org.stablebar.mixer."

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private let tapID = UUID()
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let gains = Gains()
    private var processes: [AudioObjectID] = []
    /// How many times the processes started or stopped playing, so the device waits only once they stayed quiet.
    private var changes = 0
    /// Whether starting the device makes it wait for the app's sound, as on macOS 27.
    private var waits = true
    private var startFailed = false
    /// StableBar's calls come one at a time, but the processes' listener runs alongside them, so what they share sits
    /// behind this.
    private let lock = NSLock()
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processesChanged() }
    private static let listenerQueue = DispatchQueue(label: "org.stablebar.mixer.taps")
    /// Hears that a start the tap made on its own failed, which leaves the app muted with nothing playing.
    private let failed: @Sendable (AppAudioTap) -> Void

    @available(macOS 14.2, *)
    init(_ plan: MixerState.Tap, failed: @escaping @Sendable (AppAudioTap) -> Void) throws {
        self.failed = failed
        do {
            gains.pointer.initialize(repeating: Float(plan.gain), count: 2)
            try check(AudioHardwareCreateProcessTap(description(of: plan.processes), &tap), "tap the app’s sound")
            let device: [String: Any] = [
                kAudioAggregateDeviceNameKey: "StableBar mixer",
                kAudioAggregateDeviceUIDKey: Self.uidPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: plan.output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: plan.output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapID.uuidString, kAudioSubTapDriftCompensationKey: true]],
            ]
            try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate), "open the app’s output")
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, Self.player(gains)), "play the app’s sound")
            follow(plan.processes.map { AudioObjectID($0) })
            try check(lock.withLock { restart() }, "play the app’s sound")
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func setGain(_ gain: Double) {
        gains.pointer[0] = Float(gain)
    }

    /// Whether the device's last start failed, which leaves the app muted with nothing playing.
    var lastStartFailed: Bool { lock.withLock { startFailed } }

    /// Changes the processes the tap mutes and plays, without stopping what plays.
    @available(macOS 14.2, *)
    func setProcesses(_ processes: [UInt32]) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: description(of: processes) as CFTypeRef) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CFTypeRef>.size), $0)
        }
        try check(status, "follow the app’s processes")
        follow(processes.map { AudioObjectID($0) })
        processesChanged()
        // `MixerState` ignores a failure reported for the processes before, so the change reports it again.
        if lastStartFailed { throw CommandFailure(message: "Could not play the app’s sound.") }
    }

    /// Starts the device should CoreAudio not have when the app plays, and makes it wait once the app stops. Starting a
    /// running device again would make it wait instead, muting what plays until the next sound.
    func setPlaying(_ playing: Bool) throws {
        guard playing else { return waitOnceQuiet() }
        try lock.withLock {
            guard proc != nil, !isRunning else { return }
            try check(restart(), "play the app’s sound")
        }
    }

    /// Stops the device and starts it again, which makes it wait for the app's sound while the app is quiet. A macOS that
    /// runs it at once instead would keep it running between sounds, so there it stays stopped while the app is quiet,
    /// and starts as soon as one of the app's processes plays. Call it with `lock` held.
    @discardableResult
    private func restart() -> OSStatus {
        guard let proc else { return noErr }
        AudioDeviceStop(aggregate, proc)
        let status = start(proc)
        if status == noErr, waits, isRunning, !processes.contains(where: Self.plays) {
            AudioDeviceStop(aggregate, proc)
            waits = false
        }
        return status
    }

    /// Makes a running device wait for the app's next sound once none of its processes played for half a second: the
    /// app's last sound reaches the device a moment after the app stops.
    private func waitOnceQuiet() {
        let change = lock.withLock {
            changes += 1
            return changes
        }
        Self.listenerQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in self?.wait(unlessChangedSince: change) }
    }

    private func wait(unlessChangedSince change: Int) {
        lock.withLock {
            guard changes == change, let proc else { return }
            // A process can report that it plays a moment after it says it changed.
            guard isRunning else { return startIfPlaying() }
            guard !processes.contains(where: Self.plays) else { return }
            if waits { reportIfFailed(restart()) } else { AudioDeviceStop(aggregate, proc) }
        }
    }

    /// The app's processes started or stopped playing, or changed. StableBar can miss the quiet between two sounds and
    /// then never asks for the next one, so the tap starts its device itself.
    private func processesChanged() {
        lock.withLock { startIfPlaying() }
        waitOnceQuiet()
    }

    /// Starts the device where it doesn't wait for the app's sound, once one of the app's processes plays. Where it
    /// waits, CoreAudio starts it. Call it with `lock` held.
    private func startIfPlaying() {
        guard !waits, let proc, !isRunning, processes.contains(where: Self.plays) else { return }
        reportIfFailed(start(proc))
    }

    /// Call it with `lock` held.
    private func start(_ proc: AudioDeviceIOProcID) -> OSStatus {
        let status = AudioDeviceStart(aggregate, proc)
        startFailed = status != noErr
        return status
    }

    /// For a start no call from StableBar made, so none can throw its failure.
    private func reportIfFailed(_ status: OSStatus) {
        if status != noErr { failed(self) }
    }

    private func follow(_ processes: [AudioObjectID]) {
        let followed = lock.withLock {
            defer { self.processes = processes }
            return self.processes
        }
        // CoreAudio announces that a process starts or stops playing as a change of `IsRunning`, not of `IsRunningOutput`.
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunning, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        for process in followed { AudioObjectRemovePropertyListenerBlock(process, &address, Self.listenerQueue, listener) }
        for process in processes { AudioObjectAddPropertyListenerBlock(process, &address, Self.listenerQueue, listener) }
    }

    private static func plays(_ process: AudioObjectID) -> Bool {
        var playing: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &playing) == noErr && playing != 0
    }

    private var isRunning: Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// Ends the tap, so the app plays as macOS does again.
    func stop() {
        follow([])
        lock.withLock {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
            proc = nil
            aggregate = AudioObjectID(kAudioObjectUnknown)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Muted even while the device waits, so a sound it starts late is cut short rather than played at full volume.
    @available(macOS 14.2, *)
    private func description(of processes: [UInt32]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes.map { AudioObjectID($0) })
        description.uuid = tapID
        description.muteBehavior = .muted
        description.isPrivate = true
        return description
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw CommandFailure(message: "Could not \(action) (\(status)).") }
    }

    /// The gain to play at, then the gain the last cycle ended at, which the next one ramps from so a change doesn't
    /// click. Written on the main actor and read on CoreAudio's I/O thread, a Float at a time.
    private final class Gains: @unchecked Sendable {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 2)

        deinit {
            pointer.deallocate()
        }
    }

    /// Copies the tap's sound, the input's last buffer, into the output's first two channels at the gain, and
    /// silences the rest. It runs on CoreAudio's I/O thread, so it neither allocates nor locks, and it isn't isolated
    /// to the main actor, which would stop it there.
    private nonisolated static func player(_ gains: Gains) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            let outputs = UnsafeMutableAudioBufferListPointer(output)
            var channels = 0
            for buffer in outputs {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                channels += Int(buffer.mNumberChannels)
            }
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard channels > 0, let source = inputs.last, source.mNumberChannels > 0,
                  let samples = source.mData?.assumingMemoryBound(to: Float.self) else { return }
            let width = Int(source.mNumberChannels)
            let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / width
            let target = gains.pointer[0]
            var gain = gains.pointer[1]
            let step = frames > 0 ? (target - gain) / Float(frames) : 0
            for frame in 0..<frames {
                gain += step
                let left = samples[frame * width] * gain
                let right = width > 1 ? samples[frame * width + 1] * gain : left
                var channel = 0
                for buffer in outputs where channel < 2 {
                    let count = Int(buffer.mNumberChannels)
                    guard count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self),
                          frame < Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / count else {
                        channel += count
                        continue
                    }
                    for index in 0..<min(count, 2 - channel) {
                        data[frame * count + index] = channels == 1 ? (left + right) / 2 : channel + index == 0 ? left : right
                    }
                    channel += count
                }
            }
            gains.pointer[1] = target
        }
    }
}
