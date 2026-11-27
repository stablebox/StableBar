import AppKit
import SwiftUI
import Testing
@testable import StableBar

/// App menus without room to expand open a tray, whose titles open a menu over it. The menu's submenus hang off the menu,
/// two windows up from the tray. A click there must reach its item: a tray that closes on the mouse-down takes the
/// submenu with it before the mouse comes up. Escape there still closes the tray, which closes the menu and its submenus.
@Test(arguments: ["Escape in the submenu", "a click elsewhere"]) @MainActor
func aClickInASubmenuLeavesTheTrayItsMenuOpenedFromOpen(closing: String) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"motion":"none"},"widgets":[{"id":"menus","type":"text","text":"Code","position":"left"}]}
    """#.utf8))
    var trayPanel: PopupPanel?
    var menuPanel: PopupPanel?
    let tray = WidgetPopup(present: { panel, _ in trayPanel = panel })
    let menu = WidgetPopup(present: { panel, _ in menuPanel = panel })
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
    let title = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    try #require(trayPanel).contentView!.addSubview(title)
    menu.toggle(AppMenu.popup([]), widget: widget, defaults: defaults, store: store, anchor: title)
    defer { menu.close() }
    func window() -> PopupPanel {
        let panel = PopupPanel(contentRect: NSRect(x: -9000, y: -6000, width: 100, height: 100),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        return panel
    }
    // A submenu, as `AppMenu.openSubmenu` attaches one.
    let submenu = window()
    try #require(menuPanel).addChildWindow(submenu, ordered: .above)
    defer { submenu.close() }
    #expect(submenu.parent?.parent === trayPanel)
    // The events go to the tray's handler alone. `NSApp.sendEvent` would reach every open popup in the test process,
    // closing those that tests running alongside this one have open.
    func click(in window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!tray.consumes(event, anchor: anchor))
    }

    try click(in: submenu)
    try #require(tray.isOpen)

    let elsewhere = window()
    defer { elsewhere.close() }
    if closing == "a click elsewhere" {
        try click(in: elsewhere)
    } else {
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: submenu.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        #expect(tray.consumes(escape, anchor: anchor))
    }
    #expect(!tray.isOpen, "Closed by \(closing)")
}
