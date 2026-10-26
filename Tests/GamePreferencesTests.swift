import Foundation
@main struct GamePreferencesTests {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: FrontendPreferences.registeredDefaults)
        let baseline = defaults.integer(forKey: "graphics.psp.resolution")
        let first = "test-" + UUID().uuidString, second = "test-" + UUID().uuidString
        defer {
            GamePreferences.end(); GamePreferences.reset(first); GamePreferences.reset(second)
            defaults.set(baseline, forKey: "graphics.psp.resolution")
        }
        GamePreferences.begin(first)
        defaults.set(3, forKey: "graphics.psp.resolution"); GamePreferences.capture(); GamePreferences.end()
        assert(defaults.integer(forKey: "graphics.psp.resolution") == baseline)
        GamePreferences.begin(second)
        assert(defaults.integer(forKey: "graphics.psp.resolution") == baseline)
        defaults.set(2, forKey: "graphics.psp.resolution"); GamePreferences.end()
        GamePreferences.begin(first)
        assert(defaults.integer(forKey: "graphics.psp.resolution") == 3)
        GamePreferences.end()
        defaults.set(["graphics.psp.resolution": baseline], forKey: "game.profile.recovery")
        defaults.set(4, forKey: "graphics.psp.resolution")
        GamePreferences.recover()
        assert(defaults.integer(forKey: "graphics.psp.resolution") == baseline)
        GamePreferences.reset(first); assert(!GamePreferences.hasProfile(first))
        let suite = "RendererReset-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        isolated.set("metal", forKey: "graphics.3ds.renderer")
        isolated.set(["graphics.3ds.renderer":"mixed", "graphics.3ds.resolution":2, "audio.volume":75], forKey:"game.profile.example")
        isolated.set(["graphics.3ds.renderer":"metal", "display.screen":"bottom"], forKey:"game.profile.recovery")
        isolated.set(["graphics.psp.resolution":3],forKey:"game.profile.psp")
        GamePreferences.restoreVulkanRenderer(in: isolated)
        assert(isolated.string(forKey:"graphics.3ds.renderer") == "vulkan")
        let profile=isolated.dictionary(forKey:"game.profile.example")!
        assert(profile["graphics.3ds.renderer"] as? String == "vulkan")
        assert(profile["graphics.3ds.resolution"] as? Int == 2 && profile["audio.volume"] as? Int == 75)
        assert(isolated.dictionary(forKey:"game.profile.recovery")?["display.screen"] as? String == "bottom")
        assert(isolated.dictionary(forKey:"game.profile.psp")?["graphics.3ds.renderer"] == nil)
        GamePreferences.restoreVulkanRenderer(in: isolated) // idempotent
        assert(isolated.dictionary(forKey:"game.profile.example")?["graphics.3ds.resolution"] as? Int == 2)
        isolated.set(false,forKey:"graphics.3ds.metalSurfaceCache")
        GamePreferences.enableMetalSurfaceCache(for:["example"],in:isolated)
        assert(isolated.bool(forKey:"graphics.3ds.metalSurfaceCache"))
        assert(isolated.dictionary(forKey:"game.profile.example")?["graphics.3ds.metalSurfaceCache"] as? Bool == true)
        assert(isolated.dictionary(forKey:"game.profile.example")?["graphics.3ds.renderer"] as? String == "vulkan")
        assert(isolated.dictionary(forKey:"game.profile.example")?["graphics.3ds.resolution"] as? Int == 2)
        assert(isolated.dictionary(forKey:"game.profile.psp")?["graphics.3ds.metalSurfaceCache"] == nil)
        print("Per-game preferences: isolation, switching, restoration, crash recovery and reset passed")
    }
}
