import Testing
import XCTest
@testable import StableBar

final class ConfigurationEditsTests: XCTestCase {
    func testTheEarlierStarterAppleLogoBecomesAnAppleMenuThatStillOpensSystemSettings() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let logo = #""type": "text", "text": "", "icon": "apple.logo", "onClick": "open -a 'System Settings'""#
        try Data(#"""
        {
          "bar": { "height": 40, "inset": 12 },
          "widgets": [
            {
              "id": "system",
              "type": "text",
              "position": "left",
              "text": "",
              "icon": "apple.logo",
              "onClick": "open -a 'System Settings'"
            },
            { "id": "styled", "position": "right", \#(logo), "style": { "foreground": "#ff8800" }, "enabled": false, "tooltip": "Settings" },
            { "id": "timed", "position": "left", \#(logo), "timeout": 5 },
            { "id": "finder", "position": "left", "type": "text", "text": "", "icon": "apple.logo", "onClick": "open -a Finder" },
            { "id": "clock", "type": "clock", "position": "right" }
          ]
        }
        """#.utf8).write(to: url)
        try migrateStarterAppleLogo(url)
        let migrated = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(Configuration.self, from: migrated)
        XCTAssertEqual(configuration.widgets.map(\.id), ["system", "styled", "timed", "finder", "clock"])
        for widget in configuration.widgets.prefix(2) {
            XCTAssertEqual(widget.content, .appleMenu(click: .systemSettings))
            XCTAssertNil(widget.icon)
            XCTAssertNil(widget.onClick)
        }
        XCTAssertEqual(configuration.widgets[0].position, .left)
        XCTAssertEqual(configuration.widgets[1].position, .right)
        XCTAssertEqual(configuration.widgets[1].style.foreground, HexColor(0xff8800ff))
        XCTAssertFalse(configuration.widgets[1].enabled)
        XCTAssertEqual(configuration.widgets[1].tooltip, "Settings")
        XCTAssertEqual(configuration.widgets[2].content, .text(""), "A command timeout is more than the starter had")
        XCTAssertEqual(configuration.widgets[3].onClick, "open -a Finder")
        let text = String(decoding: migrated, as: UTF8.self)
        XCTAssertTrue(text.contains(#""bar": { "height": 40, "inset": 12 }"#), text)
        XCTAssertTrue(text.contains(#"{ "id": "clock", "type": "clock", "position": "right" }"#), text)

        try migrateStarterAppleLogo(url)
        XCTAssertEqual(try Data(contentsOf: url), migrated, "A converted file isn't written again")
    }

    func testAnOffsetAnEarlierSetupWroteForBelowTheMenuBarBecomesBelowMenuBar() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let earlier: Set<Double> = [22, 32]
        for offset in [22, 32] {
            try Data(#"""
            {
              "bar": { "height": 40, "offset": \#(offset) },
              "widgets": [ { "id": "clock", "type": "clock", "position": "right" } ]
            }
            """#.utf8).write(to: url)
            try migrateEarlierBelowMenuBarOffset(url, offsets: earlier)
            let migrated = try Data(contentsOf: url)
            let bar = try JSONDecoder().decode(Configuration.self, from: migrated).bar
            XCTAssertTrue(bar.belowMenuBar, "offset \(offset)")
            XCTAssertEqual(bar.offset, 0, "offset \(offset)")
            XCTAssertEqual(bar.height, 40)
            let text = String(decoding: migrated, as: UTF8.self)
            XCTAssertTrue(text.contains(#"{ "id": "clock", "type": "clock", "position": "right" }"#), text)

            try migrateEarlierBelowMenuBarOffset(url, offsets: earlier)
            XCTAssertEqual(try Data(contentsOf: url), migrated, "A converted file isn't written again")
        }
    }

    func testAnOffsetNoEarlierSetupWroteStaysAsItIs() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        for bar in [#""bar": { "offset": 12 }"#, #""bar": { "offset": 0 }"#, #""bar": { "offset": 22, "belowMenuBar": false }"#,
                    #""bar": { "offset": 22, "belowMenuBar": true }"#, #""bar": { "height": 40 }"#,
                    #""screens": { "laptop": { "bar": { "offset": 22 } } }"#] {
            let original = Data("{ \(bar), \"widgets\": [] }".utf8)
            try original.write(to: url)
            try migrateEarlierBelowMenuBarOffset(url, offsets: [22, 32])
            XCTAssertEqual(try Data(contentsOf: url), original, bar)
        }
    }

    func testAGradientEditReplacesASavedColorPairInsteadOfMergingWithIt() throws {
        let gradient: ConfigurationValue = .object(["gradient": .object(["colors": .array([.string("#111111"), .string("#222222")])])])
        let main: [String: ConfigurationValue] = [
            "defaults": .object(["background": .object(["light": .string("#444444"), "dark": .string("#555555")]), "fontSize": .number(12)])
        ]
        var ids: [String] = []
        let result = try ConfigurationEdit(action: .defaults, properties: ["background": gradient]).applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(result["defaults"], .object(["background": gradient, "fontSize": .number(12)]))
    }

    func testRootUnsetAddressesWidgetsAndProfilesByNameAndKeepsRequiredProfileConfiguration() throws {
        let main: [String: ConfigurationValue] = [
            "widgets": .array([.object(["id": .string("clock"), "style": .object(["foreground": .string("#ffffff")])])]),
            "profiles": .array([.object(["name": .string("night"), "configuration": .object(["bar": .object(["height": .number(40)])])])])
        ]
        let edit = ConfigurationEdit(action: .unset, properties: [
            "widgets": .object(["clock": .object(["style": .object(["foreground": .null])])]),
            "profiles": .object(["night": .object(["configuration": .object(["bar": .object(["height": .null])])])])
        ])
        var ids = ["clock"]
        let result = try edit.applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(result["widgets"], .array([.object(["id": .string("clock")])]))
        XCTAssertEqual(result["profiles"], .array([.object(["name": .string("night"), "configuration": .object([:])])]))
        XCTAssertEqual(try result["profiles"]?.decoded([ConfigurationProfile].self).first?.configuration, [:])
    }

    func testUnsetRemovesEmptyUnrelatedConfigurationKeysAndLeavesOtherValues() throws {
        let nested: ConfigurationValue = .object(["configuration": .object(["height": .number(40)]), "keep": .bool(true)])
        let main: [String: ConfigurationValue] = [
            "tokens": .object(["custom": nested]),
            "widgets": .array([.object(["id": .string("clock"), "custom": nested])]),
            "profiles": .array([.object(["name": .string("night"), "configuration": .object(["tokens": .object(["custom": nested])])])])
        ]
        let mask: ConfigurationValue = .object(["configuration": .object(["height": .null])])
        var ids = ["clock"]
        let result = try ConfigurationEdit(action: .unset, properties: [
            "tokens": .object(["custom": mask]), "widgets": .object(["clock": .object(["custom": mask])]),
            "profiles": .object(["night": .object(["configuration": .object(["tokens": .object(["custom": mask])])])])
        ]).applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(try result["tokens"]?.decoded([String: ConfigurationValue].self)["custom"], .object(["keep": .bool(true)]))
        let widget = try XCTUnwrap(result["widgets"]?.decoded([[String: ConfigurationValue]].self).first)
        XCTAssertEqual(widget["custom"], .object(["keep": .bool(true)]))
        let profile = try XCTUnwrap(result["profiles"]?.decoded([ConfigurationProfile].self).first)
        XCTAssertEqual(profile.configuration["tokens"], .object(["custom": .object(["keep": .bool(true)])]))
        let byID = try ConfigurationEdit(action: .unset, id: "clock", properties: ["custom": mask]).applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(try byID["widgets"]?.decoded([[String: ConfigurationValue]].self).first?["custom"], .object(["keep": .bool(true)]))
    }

    func testUnsetDoesNotAddressUnrelatedNestedArraysByName() throws {
        let main: [String: ConfigurationValue] = ["tokens": .object([
            "custom": .object(["profiles": .array([.object(["name": .string("nested"), "configuration": .object(["height": .number(40)])])])])
        ])]
        let edit = ConfigurationEdit(action: .unset, properties: ["tokens": .object([
            "custom": .object(["profiles": .object(["nested": .object(["configuration": .object(["height": .null])])])])
        ])])
        var ids: [String] = []
        XCTAssertEqual(try edit.applying(to: main, widgetIDs: &ids), main)
    }

    func testPackageSourceEditsUpsertAndRemoveByID() throws {
        var ids: [String] = []
        let acme: [String: ConfigurationValue] = ["id": .string("acme"), "name": .string("Acme"), "url": .string("https://a.example/index.json")]
        var root = try ConfigurationEdit(action: .packageSource, properties: acme).applying(to: [:], widgetIDs: &ids)
        root = try ConfigurationEdit(action: .packageSource, properties: acme.merging(["name": .string("Acme Inc")]) { $1 }).applying(to: root, widgetIDs: &ids)
        XCTAssertEqual(root["packageSources"], .array([.object(acme.merging(["name": .string("Acme Inc")]) { $1 })]))
        root = try ConfigurationEdit(action: .packageSource, id: "acme").applying(to: root, widgetIDs: &ids)
        XCTAssertNil(root["packageSources"])
    }
}

@Test func soundWidgetsSavedBefore019TurnOnTheirDetails() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let earlier = Data(#"""
    {
      "widgets": [
        { "id": "sound", "type": "audio", "position": "right" },
        { "id": "off", "type": "audio", "position": "right", "details": false },
        { "id": "clicked", "type": "audio", "position": "right", "onClick": "open -a 'Audio MIDI Setup'" },
        { "id": "cleared", "type": "audio", "position": "right", "open": null },
        { "id": "battery", "type": "battery", "position": "right" }
      ]
    }
    """#.utf8)
    try earlier.write(to: url)
    try migrateEarlierSoundDetails(url, pinned: "0.19.0")
    #expect(try Data(contentsOf: url) == earlier, "A file saved by 0.19.0 keeps what it says")

    try migrateEarlierSoundDetails(url, pinned: "0.19.0-beta.20261123164352.1618")
    let widgets = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)).widgets
    #expect(widgets.map(\.details) == [true, false, false, true, false])
}

@Test func starterClocksSavedBefore019OpenTheirDetails() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let earlier = Data(#"""
    {
      "widgets": [
        { "id": "apple", "type": "appleMenu", "position": "left" },
        { "id": "app-menu", "type": "appMenu", "position": "left" },
        { "id": "sound", "type": "audio", "position": "right", "details": true },
        { "id": "clock", "type": "clock", "position": "right", "format": "EEE d MMM  HH:mm", "onClick": "open -a Calendar" },
        { "id": "menu-bar-items", "type": "menuBarItems", "position": "right" },
        { "id": "off", "type": "clock", "position": "right", "onClick": "open -a Calendar", "details": false },
        { "id": "other", "type": "clock", "position": "right", "onClick": "open -a Clock" }
      ]
    }
    """#.utf8)
    try earlier.write(to: url)
    try migrateEarlierStarterClock(url, pinned: "0.19.0")
    #expect(try Data(contentsOf: url) == earlier, "A file saved by 0.19.0 keeps what it says")

    try migrateEarlierStarterClock(url, pinned: "0.19.0-beta.20261123164352.1618")
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    let widgets = try #require(try document["widgets"]?.decoded([[String: ConfigurationValue]].self))
    #expect(SetupPreferences.isMenuBarStarter(Array(widgets.prefix(5)), remembered: []))
    #expect(widgets[5]["onClick"] == .string("open -a Calendar"))
    #expect(widgets[6]["onClick"] == .string("open -a Clock"))
}

@Test func setupsDateAndTimeSavedBefore019BecomeOneClock() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    func pair(dateStyle: String = "", more: String = "") -> Data {
        Data(#"""
        {
          "widgets": [
            { "id": "date", "type": "clock", "position": "right", "role": "secondary", "details": true, "format": "EEE d MMM"\#(dateStyle) },
            { "id": "clock", "type": "clock", "position": "right", "role": "time", "details": true, "format": "HH:mm" },
            { "id": "menu-bar-items", "type": "menuBarItems", "position": "right" }
          ],
          "widgetOrder": ["date", "clock", "menu-bar-items"]\#(more)
        }
        """#.utf8)
    }
    func widgets() throws -> [[String: ConfigurationValue]] {
        try #require(try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))["widgets"]?
            .decoded([[String: ConfigurationValue]].self))
    }
    try pair().write(to: url)
    try migrateSetupDateAndTime(url, pinned: "0.19.0")
    #expect(try Data(contentsOf: url) == pair(), "A file saved by 0.19.0 keeps what it says")

    try migrateSetupDateAndTime(url, pinned: "0.19.0-beta.20261123164352.1618")
    #expect(try widgets() == [
        ["id": .string("clock"), "type": .string("clock"), "position": .string("right"), "details": .bool(true),
         "format": .string("EEE d MMM  HH:mm"), "layout": WidgetLayoutChoice.dateAndTimeApart.layout],
        ["id": .string("menu-bar-items"), "type": .string("menuBarItems"), "position": .string("right")]
    ])
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    #expect(document["widgetOrder"] == .array([.string("clock"), .string("menu-bar-items")]))

    for unrelated in [#", "profiles": [{ "name": "Plain" }]"#, #", "widgetOverrides": {}"#,
                      #", "profiles": [{ "name": "Laptop", "configuration": { "widgetOverrides": {} } }]"#] {
        try pair(more: unrelated).write(to: url)
        try migrateSetupDateAndTime(url, pinned: nil)
        #expect(try widgets().map { $0["id"] } == [.string("clock"), .string("menu-bar-items")], "\(unrelated) names neither clock")
    }

    for customized in [pair(dateStyle: #", "style": { "fontSize": 11 }"#),
                       pair(more: #", "profiles": [{ "name": "Laptop", "configuration": { "widgetOverrides": { "date": { "enabled": false } } } }]"#),
                       pair(more: #", "profiles": [{ "name": "Laptop", "configuration": { "screens": { "laptop": { "layout": { "left": ["date"], "right": ["clock"] } } } } }]"#)] {
        try customized.write(to: url)
        try migrateSetupDateAndTime(url, pinned: nil)
        #expect(try Data(contentsOf: url) == customized)
    }
}
