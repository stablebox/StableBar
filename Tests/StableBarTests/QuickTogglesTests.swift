import CoreWLAN
import Foundation
@testable import StableBar
import Testing

private let now = Date(timeIntervalSince1970: 1_000_000)

@Test func keepAwakeHoldsItsAssertionUntilItsTimeRunsOut() {
    var state = KeepAwakeState()
    #expect(state.handle(.turnOn(.minutes(15), now: now)) == [.endAt(now + 900), .hold(.display)])
    #expect(state.minutesLeft(at: now + 61) == 14)
    #expect(state.handle(.turnOn(.minutes(240), now: now)) == [.endAt(now + 14_400)])
    #expect(state.handle(.ended) == [.endAt(nil), .release])
    #expect(state.mode == .off)
    #expect(state.handle(.ended).isEmpty)
}

@Test func keepAwakeLetsTheDisplaySleepAndWaitsForPowerWhenAsked() {
    var state = KeepAwakeState()
    _ = state.handle(.turnOn(.turnedOff, now: now))
    let options = KeepAwakeState.Options(displaySleeps: true, onPowerOnly: true)
    #expect(state.handle(.setOptions(options)) == [.save(options), .hold(.system)])
    #expect(state.handle(.powerChanged(onPower: false)) == [.release])
    #expect(state.mode == .on(.turnedOff, end: nil))
    #expect(state.handle(.powerChanged(onPower: true)) == [.hold(.system)])
    #expect(state.handle(.turnOff) == [.endAt(nil), .release])
}

@Test func keepAwakeStopsWhenTheAppItWaitsForQuits() {
    var state = KeepAwakeState()
    #expect(state.handle(.turnOn(.appQuits(.init(pid: 42, name: "Xcode")), now: now)) == [.endAt(nil), .hold(.display)])
    #expect(state.handle(.appQuit(7)).isEmpty)
    #expect(state.handle(.appQuit(42)) == [.release])
    #expect(state.mode == .off)
}

/// When macOS refuses the assertion, Keep awake turns off, and turning it on again asks again.
@Test func keepAwakeTurnsOffWhenMacOSRefusesItsAssertion() {
    var state = KeepAwakeState()
    _ = state.handle(.turnOn(.turnedOff, now: now))
    #expect(state.handle(.holdFailed) == [.endAt(nil), .release])
    #expect(state.mode == .off && state.holding == nil)
    #expect(state.handle(.turnOn(.turnedOff, now: now)) == [.endAt(nil), .hold(.display)])
}

@Test func theNetworkListShowsEachNameOnceSavedFirstThenTheStrongest() {
    let found = [WiFiNetwork(ssid: "Café", rssi: -70, secure: false, known: false),
                 WiFiNetwork(ssid: "Office", rssi: -80, secure: true, known: true),
                 WiFiNetwork(ssid: "Office", rssi: -60, secure: true, known: true),
                 WiFiNetwork(ssid: "Home", rssi: -50, secure: true, known: true),
                 WiFiNetwork(ssid: "Neighbours", rssi: -70, secure: true, known: false)]
    let list = WiFiNetwork.list(found, joined: "Home")
    #expect(list.map(\.ssid) == ["Office", "Café", "Neighbours"])
    #expect(list.first?.rssi == -60)
}

@Test func aNewScanUpdatesTheListInPlaceAndAddsNewNetworksAfter() {
    let shown = [WiFiNetwork(ssid: "Office", rssi: -60, secure: true, known: true),
                 WiFiNetwork(ssid: "Café", rssi: -70, secure: false, known: false),
                 WiFiNetwork(ssid: "Gone", rssi: -80, secure: true, known: false)]
    let found = [WiFiNetwork(ssid: "Café", rssi: -55, secure: false, known: false),
                 WiFiNetwork(ssid: "Office", rssi: -65, secure: true, known: true),
                 WiFiNetwork(ssid: "Home", rssi: -40, secure: true, known: true),
                 WiFiNetwork(ssid: "New", rssi: -50, secure: true, known: false)]
    let merged = WiFiNetwork.merged(shown, with: found, joined: "Home")
    #expect(merged.map(\.ssid) == ["Office", "Café", "New"])
    #expect(merged.map(\.rssi) == [-65, -55, -50])
}

@Test func aSecuredNetworkAsksForItsPasswordAndAgainWhenItDoesNotWork() {
    var join = WiFiJoin()
    let office = WiFiNetwork(ssid: "Office", rssi: -60, secure: true, known: true)
    #expect(join.handle(.choose(office)).isEmpty)
    #expect(join.mode == .asking("Office", wrong: false))
    #expect(join.handle(.submit(password: "wrong")) == [.join("Office", password: "wrong")])
    #expect(join.handle(.choose(office)).isEmpty)
    #expect(join.handle(.failure(NSError(domain: CWErrorDomain, code: CWErr.cwInvalidPMKErr.rawValue))).isEmpty)
    #expect(join.mode == .asking("Office", wrong: true))
    _ = join.handle(.submit(password: "right"))
    _ = join.handle(.joined)
    #expect(join.mode == .idle)
}

@Test func aSecuredNetworkSaysWhyItCouldNotJoinForAnythingButItsPassword() {
    var join = WiFiJoin()
    let timeout = NSError(domain: CWErrorDomain, code: CWErr.cwTimeoutErr.rawValue)
    _ = join.handle(.choose(WiFiNetwork(ssid: "Office", rssi: -60, secure: true, known: true)))
    _ = join.handle(.submit(password: "right"))
    _ = join.handle(.failure(timeout))
    #expect(join.mode == .failed("Office", message: errorMessage(timeout)))
    #expect(WiFiJoin.Event.failure(NSError(domain: CWErrorDomain, code: CWErr.cwSupplicantTimeoutErr.rawValue)) == .wrongPassword)
    #expect(WiFiJoin.Event.failure(CommandFailure(message: "Office is out of range.")) == .failed(message: "Office is out of range."))
}

@Test func anOpenNetworkJoinsAtOnceAndSaysWhyItCouldNot() {
    var join = WiFiJoin()
    #expect(join.handle(.choose(WiFiNetwork(ssid: "Café", rssi: -70, secure: false, known: false))) == [.join("Café", password: nil)])
    _ = join.handle(.failed(message: "Café is out of range."))
    #expect(join.mode == .failed("Café", message: "Café is out of range."))
}

@Test func ejectDisksTriesEveryDriveOnceAndSaysWhichItCouldNot() async {
    let volumes = [("Backup", "disk4"), ("Backup Photos", "disk4"), ("Camera", "disk5")].map { name, drive in
        DiskVolume(name: name, path: NSTemporaryDirectory(), format: "", total: 1, available: 1, isLocal: true, ejectable: true, drive: drive)
    }
    let refusal = CocoaError(.fileWriteUnknown)
    let error = await #expect(throws: CommandFailure.self) {
        try await QuickToggles.ejectDrives(of: volumes, with: VolumeEjector { _, _ in throw refusal })
    }
    #expect(error?.message == "Backup: \(errorMessage(refusal))\nCamera: \(errorMessage(refusal))")
}

@Test func aSliderSendsTheDisplayOnlyItsLatestBrightness() {
    var writes = LatestWrite<UInt16>()
    #expect(writes.handle(.set(10)) == [.write(10)])
    #expect(writes.handle(.set(20)).isEmpty)
    #expect(writes.handle(.set(30)).isEmpty)
    #expect(writes.handle(.finished) == [.write(30)])
    #expect(writes.handle(.finished).isEmpty)
    #expect(writes.mode == .idle)
    #expect(writes.handle(.set(40)) == [.write(40)])
}

@Test func theBrightnessSliderDimsInSoftwareBelowTheDisplaysOwnMinimum() {
    func split(_ level: Double, _ own: Bool) -> [Double?] {
        let (brightness, dim) = BrightnessScale.split(level, ownBrightness: own)
        return [brightness, dim]
    }
    #expect(split(1, true) == [1, 0])
    #expect(split(BrightnessScale.dimmedShare, true) == [0, 0])
    #expect(split(0, true) == [0, BrightnessScale.deepest])
    #expect(split(1, false) == [nil, 0])
    #expect(split(0, false) == [nil, BrightnessScale.deepest])
    for level in [0, 0.1, 0.2, 0.5, 1.0] {
        for own in [true, false] {
            let (brightness, dim) = BrightnessScale.split(level, ownBrightness: own)
            #expect(abs(BrightnessScale.level(brightness: brightness, dim: dim) - level) < 1e-9, "\(level) \(own)")
        }
    }
}

@Test func theResolutionsAreOnePerSizeInTheDisplaysShapeSharpWhereTheyCanBe() {
    func mode(_ id: Int32, _ width: Int, _ height: Int, scale: Int = 1, hz: Double = 60, isDefault: Bool = false) -> DisplayModeOption {
        DisplayModeOption(id: id, width: width, height: height, pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: hz,
                          usable: true, isDefault: isDefault)
    }
    // Trimmed from a 3440 × 1440 ultrawide display.
    let native = mode(1, 3440, 1440, isDefault: true)
    let modes = [native, mode(2, 1720, 720, scale: 2), mode(3, 1720, 720), mode(4, 1920, 804), mode(5, 1920, 804, hz: 50),
                 mode(6, 1920, 1080), mode(7, 1280, 536), mode(8, 1024, 768, hz: 75)]
    #expect(DisplayModeOption.choices(modes, current: native).map(\.id) == [7, 2, 4, 1])
    let wide = mode(6, 1920, 1080)
    #expect(DisplayModeOption.choices(modes, current: wide).map(\.id) == [7, 2, 4, 6, 1])
}

@Test func ddcPacketsCarryTheirChecksumAndRepliesAreChecked() {
    #expect(DDC.getPacket(DDC.brightness) == [0x82, 0x01, 0x10, 0xAC])
    let checksum: UInt8 = [0x6E, 0x51, 0x84, 0x03, 0x10, 0x00, 0x46].reduce(0, ^)
    #expect(DDC.setPacket(DDC.brightness, 70) == [0x84, 0x03, 0x10, 0x00, 0x46, checksum])
    // A Dell U3423WE's answer at full brightness.
    let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x6B]
    #expect(DDC.reply(reply, for: DDC.brightness).map { [$0.value, $0.maximum] } == [100, 100])
    var garbled = reply
    garbled[9] = 0x32
    #expect(DDC.reply(garbled, for: DDC.brightness) == nil)
    var unsupported = reply
    unsupported[3] = 0x01
    unsupported[10] ^= 0x01
    #expect(DDC.reply(unsupported, for: DDC.brightness) == nil)
    #expect(DDC.reply(reply, for: 0x12) == nil)
    // A display that counts to 255, and one that says 0 for its maximum, which means 100.
    func answer(value: UInt8, maximum: UInt8) -> [UInt8] {
        let bytes: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, maximum, 0x00, value]
        return bytes + [bytes.reduce(0x50, ^)]
    }
    #expect(DDC.reply(answer(value: 128, maximum: 255), for: DDC.brightness).map { [$0.value, $0.maximum] } == [128, 255])
    #expect(DDC.reply(answer(value: 40, maximum: 0), for: DDC.brightness).map { [$0.value, $0.maximum] } == [40, 100])
}

@Test func aSpeedTestReadsWhatNetworkQualityPrints() throws {
    let json = Data(#"{"dl_throughput": 412000000, "ul_throughput": 38500000, "responsiveness": 2401.5, "interface_name": "en0"}"#.utf8)
    #expect(try NetworkDetails.speedTest(json: json) == .init(download: 412_000_000, upload: 38_500_000, responsiveness: 2401.5))
    #expect(try NetworkDetails.speedTest(json: Data("{}".utf8)) == .init())
}
