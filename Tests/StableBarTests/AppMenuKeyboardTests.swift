import AppKit
import SwiftUI
import Testing
@testable import StableBar

/// Another app's menus leave the keyboard with that app, as its native menus do: an app can drop a menu command that
/// arrives while none of its windows has the keyboard, as VS Code does. StableBar's own popups still take it.
@Test @MainActor func anAppsMenusNeverTakeTheKeyboardFromTheApp() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"motion":"none"},"widgets":[{"id":"menus","type":"text","text":"Code","position":"left"}]}
    """#.utf8))
    var presented: [PopupPanel] = []
    let tray = WidgetPopup(present: { panel, _ in presented.append(panel) })
    let menu = WidgetPopup(present: { panel, _ in presented.append(panel) })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: tray)
    store.configuration = configuration
    store.barPresentation.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    let defaults = configuration.popupDefaults.popupStyle(over: configuration.defaults)
    let anchor = try #require(bar.anchors(widget.id).first)

    tray.showRow(widget: widget, defaults: defaults, store: store, anchor: anchor, sidePadding: 10) { Text("File") }
    defer { tray.close() }
    let trayPanel = try #require(presented.last)
    #expect(!trayPanel.canBecomeKey, "The tray of an app's menu titles")
    let title = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    trayPanel.contentView!.addSubview(title)
    menu.toggle(AppMenu.popup([]), widget: widget, defaults: defaults, store: store, anchor: title)
    defer { menu.close() }
    #expect(try !#require(presented.last).canBecomeKey, "A menu opened from the tray")
    let menuPanel = try #require(presented.last)
    let row = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    menuPanel.contentView!.addSubview(row)
    // With nothing to read, the submenu opens empty, and no other app is asked for anything.
    let appMenu = AppMenu(checkAccess: { true }, readAttribute: { _, _ in nil })
    appMenu.openSubmenu(AXUIElementCreateApplication(1), beside: row) { _ in EmptyView() }
    defer { appMenu.closeSubmenus(after: nil) }
    let submenu = try #require(menuPanel.childWindows?.compactMap { $0 as? PopupPanel }.last { $0.title == "App submenu" })
    #expect(!submenu.canBecomeKey, "A submenu of a menu opened from the tray")
    appMenu.closeSubmenus(after: nil)
    menu.close()
    tray.close()

    tray.toggle(AppMenu.popup([]), widget: widget, defaults: defaults, store: store, anchor: anchor)
    #expect(try !#require(presented.last).canBecomeKey, "A menu opened from the bar")
    tray.close()

    let own = try JSONDecoder().decode(PopupConfiguration.self, from: Data(#"{"style":{},"layout":{"type":"text","text":"Details"}}"#.utf8))
    tray.toggle(own, widget: widget, defaults: defaults, store: store, anchor: anchor)
    #expect(try #require(presented.last).canBecomeKey, "A widget's own popup")
}
