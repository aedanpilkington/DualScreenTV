import Foundation

// Native Settings still edits normal defaults. During a session those defaults
// are a temporary workspace for this game; the library defaults are restored.
@MainActor enum GamePreferences {
    private static var gameID: String?
    private static var baseline: [String: Any] = [:]
    static var active: Bool { gameID != nil }
    static let prefixes = ["graphics.", "display.", "remote.", "controls.", "emulation.", "gamepad."]
    static var keys: [String] { FrontendPreferences.registeredDefaults.keys.filter { key in prefixes.contains { key.hasPrefix($0) } } }
    private static func profileKey(_ id: String) -> String { "game.profile." + id }
    static func begin(_ id: String) {
        guard gameID == nil else { return }
        let defaults = UserDefaults.standard
        defaults.register(defaults: FrontendPreferences.registeredDefaults)
        baseline = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        defaults.set(baseline, forKey: "game.profile.recovery")
        gameID = id
        for (key, value) in defaults.dictionary(forKey: profileKey(id)) ?? [:] where keys.contains(key) { defaults.set(value, forKey: key) }
    }
    static func capture() {
        guard let id = gameID else { return }
        let defaults = UserDefaults.standard
        let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        if !NSDictionary(dictionary: defaults.dictionary(forKey: profileKey(id)) ?? [:]).isEqual(to: values) { defaults.set(values, forKey: profileKey(id)) }
    }
    static func end() {
        guard gameID != nil else { return }
        capture()
        for (key, value) in baseline { UserDefaults.standard.set(value, forKey: key) }
        UserDefaults.standard.removeObject(forKey: "game.profile.recovery")
        baseline = [:]; gameID = nil
    }
    static func recover() {
        guard !active, let recovery = UserDefaults.standard.dictionary(forKey: "game.profile.recovery") else { return }
        for (key, value) in recovery where keys.contains(key) { UserDefaults.standard.set(value, forKey: key) }
        UserDefaults.standard.removeObject(forKey: "game.profile.recovery")
    }
    // Explicit support action, never a launch migration: retain every unrelated
    // preference while clearing renderer overrides that otherwise win at boot.
    static func restoreVulkanRenderer(in defaults: UserDefaults = .standard) {
        guard !active else { return }
        let renderer = "graphics.3ds.renderer"
        defaults.set("vulkan", forKey: renderer)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("game.profile.") {
            guard var profile = defaults.dictionary(forKey: key), profile[renderer] != nil else { continue }
            profile[renderer] = "vulkan"
            defaults.set(profile, forKey: key)
        }
    }
    static func enableMetalSurfaceCache(for ids: [String], in defaults: UserDefaults = .standard) {
        guard !active else { return }
        let key="graphics.3ds.metalSurfaceCache"
        defaults.set(true,forKey:key)
        for id in ids {
            guard var profile=defaults.dictionary(forKey:profileKey(id)) else {continue}
            profile[key]=true;defaults.set(profile,forKey:profileKey(id))
        }
    }
    static func reset(_ id: String) { UserDefaults.standard.removeObject(forKey: profileKey(id)) }
    static func hasProfile(_ id: String) -> Bool { UserDefaults.standard.dictionary(forKey: profileKey(id)) != nil }
}
