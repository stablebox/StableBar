import Foundation
import Testing
@testable import StableBar

@MainActor struct ProfileChangeAnimationTests {
    private func bar(_ json: String) throws -> BarSettings {
        try JSONDecoder().decode(BarSettings.self, from: Data(json.utf8))
    }

    @Test func profilesChangingOnTheirOwnMoveTheBarWithItsMotion() throws {
        let snappy = try bar(#"{"motion":"snappy","animationDuration":0.5}"#)
        #expect(BarStore.profileChangeAnimation(snappy, profilesChange: true, editing: false, reduceMotion: false)
            == WidgetAnimation(curve: .snappy, duration: 0.5))
        #expect(BarStore.profileChangeAnimation(try bar("{}"), profilesChange: true, editing: false, reduceMotion: false)
            == BarMotion.smooth.animation)
    }

    @Test(arguments: [(false, false, false), (true, true, false), (true, false, true)])
    func editsEditingAndReduceMotionChangeTheBarAtOnce(profilesChange: Bool, editing: Bool, reduceMotion: Bool) throws {
        #expect(BarStore.profileChangeAnimation(try bar("{}"), profilesChange: profilesChange, editing: editing,
                                                reduceMotion: reduceMotion) == nil)
    }

    /// A widget that a profile turns on for one app comes and goes as that app comes to the front and leaves it.
    @Test func focusedAppProfileShowsAndHidesItsWidget() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"clock","type":"clock","position":"right"},{"id":"usage","type":"text","text":"Usage","position":"right","display":[]}],
         "profiles":[{"name":"Code","when":{"app":"com.example.code"},
                      "configuration":{"widgetOverrides":{"usage":{"display":"all"}}}}]}
        """#)
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        store.configurationStore.refreshContext(ConfigurationContext(app: "com.example.other"))
        store.configurationStore.reloadConfiguration()
        defer { store.stop() }
        let usage = { store.configuration?.widgets.first { $0.id == "usage" }?.display }
        #expect(usage() == .ids([]))
        store.configurationStore.refreshContext(ConfigurationContext(app: "com.example.code"))
        #expect(store.activeProfiles == ["Code"])
        #expect(usage() == .all)
        store.configurationStore.refreshContext(ConfigurationContext(app: "com.example.other"))
        #expect(store.activeProfiles.isEmpty)
        #expect(usage() == .ids([]))
    }
}
