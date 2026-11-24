import AppKit
import CoreGraphics
import Darwin

/// The private macOS calls StableBar makes, looked up at runtime rather than bound at launch. Each is nil on a macOS
/// that no longer has it, so the feature that needs it turns off and the rest of StableBar keeps working. Adding a
/// call is a maintainer's decision (AGENTS.md).
enum PrivateAPI {
    /// `RTLD_DEFAULT`: every image already loaded, which includes SkyLight through AppKit.
    private static var loaded: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

    static func symbol<Function>(_ name: String, in image: UnsafeMutableRawPointer? = loaded, as type: Function.Type) -> Function? {
        dlsym(image, name).map { unsafeBitCast($0, to: type) }
    }

    // Hiding and revealing the macOS menu bar.
    static let mainConnectionID = symbol("CGSMainConnectionID", as: (@convention(c) () -> Int32).self)
    static let setMenuBarInsetAndAlpha = symbol(
        "CGSSetMenuBarInsetAndAlpha", as: (@convention(c) (Int32, Double, Double, Float) -> CGError).self)
    static let setMenuBarVisibilityOverride = symbol(
        "SLSSetMenuBarVisibilityOverrideOnDisplay", as: (@convention(c) (Int32, CGDirectDisplayID, Bool) -> CGError).self)

    // Clicking in the macOS menu bar without the pointer. A mouse event posted to an app names the window it's for in a
    // field CoreGraphics has no name for, and carries its place in that window.
    static let eventWindowField = CGEventField(rawValue: 51)
    static let setEventWindowLocation = symbol("CGEventSetWindowLocation", as: (@convention(c) (CGEvent, CGPoint) -> Void).self)

    // Reading Spaces. The copy calls return an array the caller owns.
    static let getActiveSpace = symbol("CGSGetActiveSpace", as: (@convention(c) (Int32) -> UInt64).self)
    static let copyManagedDisplaySpaces = symbol(
        "CGSCopyManagedDisplaySpaces", as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
    static let copySpacesForWindows = symbol(
        "CGSCopySpacesForWindows", as: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)

    /// Locking the screen, like the Apple menu's Lock Screen: the login framework's call, which returns 0 once locked.
    /// The framework stays open for good: closing it would leave this function pointing at unloaded code.
    static let lockScreenImmediate: (@convention(c) () -> Int32)? = {
        guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) else {
            return nil
        }
        return symbol("SACLockScreenImmediate", in: login, as: (@convention(c) () -> Int32).self)
    }()

    // System Audio Recording, which the Sound details' mixer needs, has no public call that checks it or asks for it.
    // TCC keeps Privacy & Security's permissions; like the login framework, it stays open for good.
    /// Whether StableBar may use a service such as `kTCCServiceAudioCapture`: 0 when allowed, 1 when refused, anything
    /// else before the person answers.
    static let accessPreflight: (@convention(c) (CFString, CFDictionary?) -> Int)? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY) else { return nil }
        return symbol("TCCAccessPreflight", in: tcc, as: (@convention(c) (CFString, CFDictionary?) -> Int).self)
    }()
    /// Asks for a service with macOS's own prompt, unless the person already answered, and calls back with whether it's
    /// allowed.
    static let accessRequest: (@convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void)? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY) else { return nil }
        return symbol("TCCAccessRequest", in: tcc,
                      as: (@convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void).self)
    }()

    // The Quick toggles' Night Shift and True Tone, as Control Center turns them on and off: CoreBrightness's clients.
    // Like the login framework, it stays open for good.
    /// Night Shift's client, on a Mac whose displays support it.
    @MainActor static let blueLightClient: NSObject? = {
        guard let type = coreBrightnessClass("CBBlueLightClient"),
              let supported = implementation("supportsBlueLightReduction", in: object_getClass(type),
                                              as: (@convention(c) (AnyClass, Selector) -> Bool).self),
              supported(type, NSSelectorFromString("supportsBlueLightReduction")) else { return nil }
        return type.init()
    }()
    /// True Tone's client, on a Mac whose display supports it.
    @MainActor static let trueToneClient: NSObject? = {
        guard let type = coreBrightnessClass("CBTrueToneClient") else { return nil }
        let client = type.init()
        return trueTone("supported", client) == true ? client : nil
    }()

    static func coreBrightnessClass(_ name: String) -> NSObject.Type? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil else { return nil }
        return NSClassFromString(name) as? NSObject.Type
    }

    /// Whether Night Shift is on: `getBlueLightStatus:` fills a status whose second byte, `enabled`, says so. Nil when it
    /// can't tell.
    @MainActor static func nightShiftEnabled() -> Bool? {
        guard let client = blueLightClient,
              let status = implementation("getBlueLightStatus:", in: type(of: client),
                                           as: (@convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool).self) else { return nil }
        // The status is 40 bytes on macOS 14 to 27; the rest leaves room for a later macOS to grow it.
        var bytes = [UInt8](repeating: 0, count: 128)
        guard bytes.withUnsafeMutableBytes({ status(client, NSSelectorFromString("getBlueLightStatus:"), $0.baseAddress!) }) else { return nil }
        return bytes[1] != 0
    }

    /// Turns Night Shift on or off until its schedule next changes it, as Control Center's button does.
    @MainActor static func setNightShift(_ on: Bool) -> Bool {
        guard let client = blueLightClient,
              let set = implementation("setEnabled:", in: type(of: client), as: (@convention(c) (NSObject, Selector, Bool) -> Bool).self)
        else { return false }
        return set(client, NSSelectorFromString("setEnabled:"), on)
    }

    /// `available` (the display can use it now) or `enabled` (it's on) of True Tone's client `client`.
    @MainActor static func trueTone(_ property: String, _ client: NSObject? = trueToneClient) -> Bool? {
        guard let client, let read = implementation(property, in: type(of: client), as: (@convention(c) (NSObject, Selector) -> Bool).self)
        else { return nil }
        return read(client, NSSelectorFromString(property))
    }

    @MainActor static func setTrueTone(_ on: Bool) -> Bool {
        guard let client = trueToneClient,
              let set = implementation("setEnabled:", in: type(of: client), as: (@convention(c) (NSObject, Selector, Bool) -> Bool).self)
        else { return false }
        return set(client, NSSelectorFromString("setEnabled:"), on)
    }

    /// The Objective-C method `selector` of `type`, or of a class's metaclass for a class method, as `function`; nil when
    /// it has none.
    private static func implementation<Function>(_ selector: String, in type: AnyClass?, as function: Function.Type) -> Function? {
        guard let type, let method = class_getInstanceMethod(type, NSSelectorFromString(selector)) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: function)
    }

    /// Night Shift's warmth, from 0 to 1. Nil when it can't tell.
    @MainActor static func nightShiftStrength() -> Double? {
        guard let client = blueLightClient,
              let read = implementation("getStrength:", in: type(of: client),
                                        as: (@convention(c) (NSObject, Selector, UnsafeMutablePointer<Float>) -> Bool).self) else { return nil }
        var strength: Float = 0
        return read(client, NSSelectorFromString("getStrength:"), &strength) ? Double(strength) : nil
    }

    @MainActor static func setNightShiftStrength(_ strength: Double) -> Bool {
        guard let client = blueLightClient,
              let set = implementation("setStrength:commit:", in: type(of: client),
                                       as: (@convention(c) (NSObject, Selector, Float, Bool) -> Bool).self) else { return false }
        return set(client, NSSelectorFromString("setStrength:commit:"), Float(strength), true)
    }

    // External displays' brightness over DDC/CI: IOKit's IOAVService calls, which its headers leave out. The service
    // follows the Create rule, and the I2C calls return 0 on success.
    static let avServiceCreateWithService: (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?)? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        return symbol("IOAVServiceCreateWithService", in: iokit, as: (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?).self)
    }()
    /// Reads `length` bytes from the chip at an address, from an offset.
    static let avServiceReadI2C: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn)? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        return symbol("IOAVServiceReadI2C", in: iokit, as: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn).self)
    }()
    static let avServiceWriteI2C: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn)? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        return symbol("IOAVServiceWriteI2C", in: iokit, as: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn).self)
    }()

    // The Quick toggles' Bluetooth power, as Control Center turns it on and off: IOBluetooth's preference calls, which its
    // headers leave out. 1 is on.
    static let bluetoothPowerState: (@convention(c) () -> Int32)? = {
        guard let bluetooth = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY) else { return nil }
        return symbol("IOBluetoothPreferenceGetControllerPowerState", in: bluetooth, as: (@convention(c) () -> Int32).self)
    }()
    static let setBluetoothPowerState: (@convention(c) (Int32) -> Void)? = {
        guard let bluetooth = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY) else { return nil }
        return symbol("IOBluetoothPreferenceSetControllerPowerState", in: bluetooth, as: (@convention(c) (Int32) -> Void).self)
    }()

    // The built-in display's brightness, from 0 to 1, as its keys set it: DisplayServices' calls, which return 0 on success.
    static let getBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let display = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return nil }
        return symbol("DisplayServicesGetBrightness", in: display, as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    }()
    static let setBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
        guard let display = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return nil }
        return symbol("DisplayServicesSetBrightness", in: display, as: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
    }()

    /// A symbol macOS keeps for its own menus, such as the Apple menu's App Store one, from the bundle AppKit loads it from.
    static func privateSymbol(_ name: String) -> NSImage? {
        Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle").flatMap { NSImage(symbolName: name, bundle: $0, variableValue: 1) }
    }
}
