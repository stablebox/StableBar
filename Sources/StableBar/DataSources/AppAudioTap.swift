import CoreAudio
import Foundation

/// One app's sound played back by StableBar: a process tap mutes the app's processes at the source, and a private
/// aggregate device reads the tap and plays it on an output device at the app's gain. Owned on the main actor.
///
/// The device waits for the app's sound: with `tapautostart`, CoreAudio starts it as the app starts playing, without
/// waiting for StableBar. It keeps running after the app stops, which keeps the output and the Mac awake, so hearing
/// that the app stopped makes it wait again.
final class AppAudioTap {
    /// The UIDs of the aggregate devices start with this. A private device is hidden from other apps but not from
    /// StableBar, so its device lists leave these out.
    static let uidPrefix = "org.stablebar.mixer."

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private let tapID = UUID()
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let gains = Gains()

    @available(macOS 14.2, *)
    init(_ plan: MixerState.Tap) throws {
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
            try check(AudioDeviceStart(aggregate, proc), "play the app’s sound")
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

    /// Changes the processes the tap mutes and plays, without stopping what plays.
    @available(macOS 14.2, *)
    func setProcesses(_ processes: [UInt32]) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFTypeRef = description(of: processes)
        try check(AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CFTypeRef>.size), &value), "follow the app’s processes")
    }

    /// Makes the device wait for the app's next sound once the app stops, and starts it should CoreAudio not have when
    /// the app plays. Starting a running device again would make it wait instead, muting what plays until the next sound.
    func setPlaying(_ playing: Bool) throws {
        guard let proc, !(playing && isRunning) else { return }
        AudioDeviceStop(aggregate, proc)
        try check(AudioDeviceStart(aggregate, proc), "play the app’s sound")
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
