import Foundation
import CoreGraphics

@main
struct FrontendPreferencesTests {
    static func main() throws {
        let wide = CGSize(width: 1920, height: 1080)
        assert(ScreenDisplayMode.original.imageSize(in: wide, zoomPercent: 10) == CGSize(width: 1440, height: 1080))
        let overscan = ScreenDisplayMode.overscan.imageSize(in: wide, zoomPercent: 10)
        assert(abs(overscan.width - 1584) < 0.01 && abs(overscan.height - 1188) < 0.01)
        assert(ScreenDisplayMode.fill.imageSize(in: wide, zoomPercent: 10) == CGSize(width: 1920, height: 1440))
        assert(ScreenDisplayMode.stretch.imageSize(in: wide, zoomPercent: 10) == wide)
        assert(ScreenDisplayMode.fill.imageSize(in: .zero, zoomPercent: 10) == .zero)
        let threeTop = CGSize(width: 400, height: 240)
        assert(ScreenDisplayMode.original.imageSize(in: wide, zoomPercent: 10, source: threeTop) == CGSize(width: 1800, height: 1080))
        assert(ScreenDisplayMode.fill.imageSize(in: wide, zoomPercent: 10, source: threeTop) == CGSize(width: 1920, height: 1152))
        let portrait = CGSize(width: 1080, height: 1920)
        assert(ScreenDisplayMode.fill.imageSize(in: portrait, zoomPercent: 10) == CGSize(width: 2560, height: 1920))
        assert(ScreenDisplayMode.overscan.imageSize(in: wide, zoomPercent: -1) == CGSize(width: 1440, height: 1080))

        var display = FrontendPreferences()
        display.integerScale = true
        assert(display.topImageSize(in: wide) == CGSize(width: 1280, height: 960))
        display.topMode = .stretch
        assert(display.topImageSize(in: wide) == wide)
        display.topMode = .original
        assert(display.topImageSize(in: CGSize(width: 128, height: 96)) == CGSize(width: 128, height: 96))
        let suite = "DualScreenTV.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: FrontendPreferences.registeredDefaults)
        var preferences = FrontendPreferences.read(from: defaults)
        assert(preferences.gbDisplayMode == .original)
        defaults.set("stretch", forKey: "display.gb.mode")
        defaults.set(15, forKey: "display.gb.overscanPercent")
        let gbPreferences = FrontendPreferences.read(from: defaults)
        assert(gbPreferences.gbDisplayMode == .stretch)
        assert(gbPreferences.gbOverscanPercent == 15)
        assert(gbPreferences.topMode == .original)
        for source in [CGSize(width: 160, height: 144), CGSize(width: 240, height: 160)] {
            assert(ScreenDisplayMode.stretch.imageSize(in: wide, zoomPercent: 10, source: source) == wide)
            let filled = ScreenDisplayMode.fill.imageSize(in: wide, zoomPercent: 10, source: source)
            assert(filled.width >= wide.width && filled.height >= wide.height)
            assert(abs(filled.width / filled.height - source.width / source.height) < 0.001)
        }
        defaults.set("invalid", forKey: "display.gb.mode")
        defaults.set(100, forKey: "display.gb.overscanPercent")
        assert(FrontendPreferences.read(from: defaults).gbDisplayMode == .original)
        assert(FrontendPreferences.read(from: defaults).gbOverscanPercent == 25)
        assert(preferences.mixWithOtherAudio)
        defaults.set(false, forKey: "audio.mixWithOthers")
        assert(!FrontendPreferences.read(from: defaults).mixWithOtherAudio)
        defaults.removeObject(forKey: "audio.mixWithOthers")
        assert(FrontendPreferences.read(from: defaults).mixWithOtherAudio)
        assert(preferences.threeDSPresentationRate == 60)
        defaults.set(30, forKey: "graphics.3ds.presentationRate")
        assert(FrontendPreferences.read(from: defaults).threeDSPresentationRate == 30)
        defaults.set(15, forKey: "graphics.3ds.presentationRate")
        assert(FrontendPreferences.read(from: defaults).threeDSPresentationRate == 60)
        assert(preferences.dsAutomaticResolution)
        defaults.set(false, forKey: "graphics.ds.automaticResolution")
        assert(!FrontendPreferences.read(from: defaults).dsAutomaticResolution)
        assert(preferences.dsPresentationRate == 60)
        defaults.set(30, forKey: "graphics.ds.presentationRate")
        assert(FrontendPreferences.read(from: defaults).dsPresentationRate == 30)
        defaults.set(15, forKey: "graphics.ds.presentationRate")
        assert(FrontendPreferences.read(from: defaults).dsPresentationRate == 60)
        assert(!preferences.dsHighResolutionCore && preferences.dsResolution == 2 && preferences.dsGPURenderer)
        assert(!preferences.dsDustGPUCore)
        defaults.set(true, forKey: "graphics.ds.dustGPUCore")
        assert(FrontendPreferences.read(from: defaults).dsDustGPUCore)
        defaults.set(false, forKey: "graphics.ds.gpuRenderer")
        assert(!FrontendPreferences.read(from: defaults).dsGPURenderer)
        defaults.set(true, forKey: "graphics.ds.gpuRenderer")
        defaults.set(true, forKey: "graphics.ds.highResolutionCore")
        assert(FrontendPreferences.read(from: defaults).dsHighResolutionCore)
        for factor in 1...8 {
            defaults.set(factor, forKey: "graphics.ds.resolution")
            assert(FrontendPreferences.read(from: defaults).dsResolution == factor)
        }
        defaults.set(99, forKey: "graphics.ds.resolution")
        assert(FrontendPreferences.read(from: defaults).dsResolution == 2)
        assert(preferences.threeDSRenderer == "vulkan")
        assert(!preferences.threeDSMetalSurfaceCache)
        defaults.set(true, forKey: "graphics.3ds.metalSurfaceCache")
        assert(FrontendPreferences.read(from: defaults).threeDSMetalSurfaceCache)
        defaults.set(false, forKey: "graphics.3ds.metalSurfaceCache")
        defaults.set("metal", forKey: "graphics.3ds.renderer")
        assert(FrontendPreferences.read(from: defaults).threeDSRenderer == "metal")
        defaults.set("mixed", forKey: "graphics.3ds.renderer")
        assert(FrontendPreferences.read(from: defaults).threeDSRenderer == "mixed")
        defaults.set("invalid", forKey: "graphics.3ds.renderer")
        assert(FrontendPreferences.read(from: defaults).threeDSRenderer == "vulkan")
        assert(preferences.threeDSResolution == 1)
        for value in [1, 2, 3, 4] {
            defaults.set(value, forKey: "graphics.3ds.resolution")
            assert(FrontendPreferences.read(from: defaults).threeDSResolution == value)
        }
        for value in [0, -1, 5, 99] {
            defaults.set(value, forKey: "graphics.3ds.resolution")
            assert(FrontendPreferences.read(from: defaults).threeDSResolution == 1)
        }
        assert(preferences.topMode == .original && preferences.topOverscanPercent == 10)
        assert(preferences.screen == .top && preferences.gamepadScreenShortcut == .triggers && preferences.remoteScreenShortcut)
        defaults.set("bottom", forKey: "display.screen")
        defaults.set("fill", forKey: "display.bottom.mode")
        defaults.set("linear", forKey: "display.bottom.filtering")
        defaults.set("4", forKey: "display.bottom.enhancement")
        defaults.set(500, forKey: "display.bottom.overscanPercent")
        let bottom = FrontendPreferences.read(from: defaults)
        assert(bottom.screen == .bottom && bottom.presentation(for: .bottom).mode == .fill)
        assert(bottom.presentation(for: .bottom).filtering == .linear && bottom.presentation(for: .bottom).enhancement == .four)
        assert(bottom.presentation(for: .bottom).zoom == 25)
        assert(bottom.presentation(for: .top).mode == .original && bottom.presentation(for: .top).filtering == .nearest)
        defaults.set("bad", forKey: "display.screen")
        defaults.set("bad", forKey: "controls.screenShortcut")
        assert(FrontendPreferences.read(from: defaults).screen == .top)
        assert(FrontendPreferences.read(from: defaults).gamepadScreenShortcut == .triggers)
        assert(preferences.enhancement == .off)
        for enhancement in ImageEnhancement.allCases {
            defaults.set(enhancement.rawValue, forKey: "display.top.enhancement")
            assert(FrontendPreferences.read(from: defaults).enhancement == enhancement)
        }
        defaults.set("8", forKey: "display.top.enhancement")
        assert(FrontendPreferences.read(from: defaults).enhancement == .off)
        defaults.set("unexpected", forKey: "display.top.enhancement")
        assert(FrontendPreferences.read(from: defaults).enhancement == .off)
        assert(preferences.filtering == .nearest && preferences.volume == 100 && !preferences.muted)
        assert(!preferences.showFPS && !preferences.showFrames && !preferences.showPerformance)
        defaults.set(999, forKey: "audio.volume")
        assert(FrontendPreferences.read(from: defaults).volume == 100)
        defaults.set(-10, forKey: "audio.volume")
        assert(FrontendPreferences.read(from: defaults).volume == 0)
        defaults.set("invalid", forKey: "display.top.filtering")
        assert(FrontendPreferences.read(from: defaults).filtering == .nearest)
        assert(!preferences.mediaButtonsEnabled)
        defaults.set(true, forKey: FrontendPreferences.mediaButtonsKey)
        assert(FrontendPreferences.read(from: defaults).mediaButtonsEnabled)
        defaults.set("stretch", forKey: "display.bottom.mode")
        assert(FrontendPreferences.read(from: defaults).topMode == .original)
        defaults.set("fill", forKey: FrontendPreferences.topModeKey)
        defaults.set("r", forKey: RemoteButton.fastForward.key)
        preferences = FrontendPreferences.read(from: defaults)
        assert(preferences.topMode == .fill && preferences.mapping(for: .fastForward) == .r)
        assert(preferences.mapping(for: .center) == .a)
        defaults.set("bad value", forKey: FrontendPreferences.topModeKey)
        defaults.set("bad value", forKey: RemoteButton.menu.key)
        assert(FrontendPreferences.read(from: defaults).topMode == .original)
        assert(FrontendPreferences.read(from: defaults).mapping(for: .menu) == .start)

        // Both existing controller layouts survive; optional controls start unused.
        let stock = FrontendPreferences.read(from: defaults)
        assert(stock.gamepadMask(pressed: [.west, .north], shapeLabels: false) == InputBinding.x.mask | InputBinding.y.mask)
        assert(stock.gamepadMask(pressed: [.west], shapeLabels: false) == InputBinding.x.mask)
        assert(stock.gamepadMask(pressed: [.west], shapeLabels: true) == InputBinding.y.mask)
        assert(stock.gamepadMask(pressed: [.north], shapeLabels: true) == InputBinding.x.mask)
        assert(stock.gamepadMask(pressed: [.leftTrigger, .rightTrigger, .leftStick, .rightStick], shapeLabels: false) == 0)
        defaults.set("r", forKey: GamepadButton.south.key)
        defaults.set("select", forKey: GamepadButton.leftTrigger.key)
        defaults.set("none", forKey: GamepadButton.menu.key)
        var custom = FrontendPreferences.read(from: defaults)
        assert(custom.gamepadMask(pressed: [.south, .leftTrigger, .menu], shapeLabels: false) == InputBinding.r.mask | InputBinding.select.mask)
        assert(custom.gamepadMask(pressed: [], shapeLabels: false) == 0)
        assert(custom.mapping(for: .center) == .a) // Remote mappings stay independent.
        defaults.set("invalid", forKey: GamepadButton.south.key)
        defaults.set("default", forKey: GamepadButton.west.key)
        custom = FrontendPreferences.read(from: defaults)
        assert(custom.gamepadMask(pressed: [.south, .west], shapeLabels: true) == InputBinding.a.mask | InputBinding.y.mask)

        for action in [InputBinding.fastForward, .pause, .reset, .saveState, .loadState] {
            assert(action.mask == 0 && action.actionMask != 0)
        }
        defaults.set("fastForward", forKey: GamepadButton.rightTrigger.key)
        custom = FrontendPreferences.read(from: defaults)
        assert(custom.gamepadBinding(for: .rightTrigger, shapeLabels: false) == .fastForward)
        assert(custom.gamepadMask(pressed: [.rightTrigger], shapeLabels: false) == 0)
        defaults.set(99, forKey: "emulation.speed")
        defaults.set(-2, forKey: "emulation.fastForwardSpeed")
        defaults.set(100, forKey: "states.slot")
        let validated = FrontendPreferences.read(from: defaults)
        assert(validated.normalSpeed == 1 && validated.fastForwardSpeed == 2 && validated.stateSlot == 10)
        var pulses = RemoteButtonPulses()
        pulses.press(.fastForward)
        pulses.press(.menu)
        for _ in 0..<3 { assert(pulses.nextMask(preferences: preferences) == InputBinding.r.mask | InputBinding.start.mask) }
        assert(pulses.nextMask(preferences: preferences) == 0)
        pulses.press(.menu)
        pulses.clear()
        assert(pulses.nextMask(preferences: preferences) == 0)
        preferences.remoteMappings[.menu] = InputBinding.none
        pulses.press(.menu)
        assert(pulses.nextMask(preferences: preferences) == 0)

        // Ensure the native Settings bundle's actual defaults and options match
        // the values used by the app, including all remappable button choices.
        let schemaURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var visited: Set<URL> = []
        func readPane(_ url: URL) throws -> [[String: Any]] {
            assert(visited.insert(url).inserted, "Duplicate or cyclic Settings pane")
            let schema = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
            let items = schema["PreferenceSpecifiers"] as! [[String: Any]]
            var settings = items.filter { $0["Key"] != nil }
            for item in items where item["Type"] as? String == "PSChildPaneSpecifier" {
                let file = item["File"] as! String
                settings += try readPane(url.deletingLastPathComponent().appendingPathComponent(file + ".plist"))
            }
            return settings
        }
        let settings = try readPane(schemaURL)
        assert(visited.count == 13, "All twelve Settings pages must be reachable")
        let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: schemaURL), format: nil) as! [String: Any]
        let rootItems = root["PreferenceSpecifiers"] as! [[String: Any]]
        assert(rootItems.allSatisfy { $0["Type"] as? String == "PSChildPaneSpecifier" })
        assert(rootItems.compactMap { $0["Title"] as? String } == [
            "Display Settings", "Graphics Settings", "DS Settings", "3DS Settings", "Game Boy Settings", "PSP Settings",
            "Controller Settings", "Audio Settings", "Debug Settings",
            "Emulation Settings", "Bottom Screen Settings", "Save Backup Settings"
        ])
        assert(Set(settings.map { $0["Key"] as! String }).count == settings.count)
        assert(settings.count == FrontendPreferences.registeredDefaults.count)
        for item in settings {
            let key = item["Key"] as! String
            let expected = FrontendPreferences.registeredDefaults[key]!
            assert((item["DefaultValue"] as! NSObject) == (expected as! NSObject))
            if item["Type"] as? String == "PSToggleSwitchSpecifier" { continue }
            let values = item["Values"] as! [Any]
            assert(values.count == (item["Titles"] as! [String]).count)
            if key == "display.top.enhancement" {
                assert(Set(values as! [String]) == Set(ImageEnhancement.allCases.map(\.rawValue)))
            }
            if key.hasPrefix("gamepad.") {
                assert(Set(values as! [String]) == Set(["default"] + InputBinding.allCases.map(\.rawValue)))
            }
            if key.hasPrefix("remote.") {
                assert(Set(values as! [String]) == Set(InputBinding.allCases.map(\.rawValue)))
            }
        }
        defaults.set(99, forKey: "graphics.psp.resolution")
        defaults.set("bad", forKey: "graphics.psp.filtering")
        defaults.set("bad", forKey: "graphics.psp.anisotropic")
        var handheld = FrontendPreferences.read(from: defaults)
        assert(handheld.pspResolution == 4 && handheld.pspFiltering == "Auto" && handheld.pspAnisotropic == "disabled")
        defaults.set(2, forKey: "graphics.psp.resolution")
        defaults.set(true, forKey: "graphics.gb.lcd")
        defaults.set(true, forKey: "graphics.gb.colourCorrection")
        handheld = FrontendPreferences.read(from: defaults)
        assert(handheld.pspResolution == 2 && handheld.gbLCD && handheld.gbColourCorrection)
        print("Preferences: display geometry, screen independence, remapping, pulse release and Settings schema passed")
    }
}
