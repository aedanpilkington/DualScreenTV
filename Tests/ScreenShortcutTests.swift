import Foundation

@main
struct ScreenShortcutTests {
    static func main() {
        var latch = ScreenShortcutLatch<GamepadButton>()
        let pair: Set<GamepadButton> = [.leftTrigger, .rightTrigger]
        assert(!latch.update(pressed: [.leftTrigger], pair: pair).switched)
        var result = latch.update(pressed: pair, pair: pair)
        assert(result.switched && result.consumed == pair)
        for _ in 0..<10 { assert(!latch.update(pressed: pair, pair: pair).switched) }
        result = latch.update(pressed: [.rightTrigger], pair: pair)
        assert(!result.switched && result.consumed == pair)
        assert(!latch.update(pressed: pair, pair: pair).switched) // Re-press one isn't a new chord.
        result = latch.update(pressed: [], pair: pair)
        assert(!result.switched && result.consumed.isEmpty)
        assert(latch.update(pressed: pair, pair: pair).switched)
        result = latch.update(pressed: pair, pair: []) // Disable while held still consumes old release tail.
        assert(!result.switched && result.consumed == pair)
        latch.clear()
        assert(!latch.update(pressed: pair, pair: []).switched)
        assert(latch.update(pressed: pair.union([.south]), pair: pair).consumed == pair)
        var remote = ScreenShortcutLatch<RemoteButton>()
        assert(remote.update(pressed: [.center, .playPause], pair: [.center, .playPause]).switched)
        assert(!remote.update(pressed: [.center], pair: [.center, .playPause]).switched)
        assert(GamepadScreenShortcut.triggers.buttons == pair)
        assert(GamepadScreenShortcut.off.buttons.isEmpty)
        assert(InputBinding.switchScreen.mask == 0 && InputBinding.switchScreen.actionMask == 32)
        let menu: Set<GamepadButton> = [.leftShoulder, .rightShoulder, .south]
        var quick = ScreenShortcutLatch<GamepadButton>()
        assert(!quick.update(pressed: [.leftShoulder, .rightShoulder], pair: menu).switched)
        assert(quick.update(pressed: menu, pair: menu).switched)
        assert(!quick.update(pressed: menu, pair: menu).switched)
        assert(quick.update(pressed: [.south], pair: menu).consumed == menu)
        assert(quick.update(pressed: [], pair: menu).consumed.isEmpty)
        assert(quick.update(pressed: menu, pair: menu).switched)
        print("Screen shortcuts: simultaneous pair, one toggle per hold, release consumption, disable/clear and remote passed")
    }
}
