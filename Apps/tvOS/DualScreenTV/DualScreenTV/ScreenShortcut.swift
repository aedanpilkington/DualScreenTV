import Foundation

nonisolated enum GamepadScreenShortcut: String, CaseIterable {
    case triggers, shoulders, menuOptions, off
    var buttons: Set<GamepadButton> {
        switch self {
        case .triggers: [.leftTrigger, .rightTrigger]
        case .shoulders: [.leftShoulder, .rightShoulder]
        case .menuOptions: [.menu, .options]
        case .off: []
        }
    }
}

// Recognize physical controls before DS/emulator remapping. Once activated,
// consume both controls until BOTH are released, preventing repeats and release
// tails from reaching the game. Individual buttons retain normal responsiveness.
nonisolated struct ScreenShortcutLatch<Button: Hashable> {
    private var latched: Set<Button> = []
    mutating func clear() { latched.removeAll() }
    mutating func update(pressed: Set<Button>, pair: Set<Button>) -> (switched: Bool, consumed: Set<Button>) {
        if !latched.isEmpty {
            if pressed.isDisjoint(with: latched) { latched.removeAll() }
            else { return (false, latched) }
        }
        if pair.count >= 2 && pair.isSubset(of: pressed) {
            latched = pair
            return (true, pair)
        }
        return (false, [])
    }
}
