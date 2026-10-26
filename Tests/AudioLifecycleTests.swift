@main
struct AudioLifecycleTests {
    static func main() {
        var state = AudioLifecycle()
        assert(!state.shouldPlay)
        state.setActive(true)
        assert(state.shouldPlay)
        // Reproduce the original failure: interruption begins while leaving,
        // never ends, then the user comes back. Foreground must retry playback.
        for _ in 0..<10 {
            state.interruptionBegan()
            assert(!state.shouldPlay)
            state.setActive(false)
            state.interruptionBegan() // Background notification after deactivation.
            assert(!state.shouldPlay)
            state.setActive(true)
            assert(state.shouldPlay)
        }
        // A real foreground interruption remains blocked until it ends.
        state.interruptionBegan()
        state.setActive(true)
        assert(!state.shouldPlay)
        state.interruptionEnded()
        assert(state.shouldPlay)
        // Interruption ending while backgrounded must not start the engine.
        state.setActive(false)
        state.interruptionEnded()
        assert(!state.shouldPlay)
        state.setActive(true)
        assert(state.shouldPlay)
        print("Audio lifecycle: foreground recovery, repeated returns and real interruptions passed")
    }
}
