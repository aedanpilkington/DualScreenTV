// A fresh foreground session must not inherit a stale background interruption.
// AudioPlayback explicitly deactivates before suspension to prevent delayed
// suspension notifications (the old suspended key isn't supported on tvOS 15+).
nonisolated struct AudioLifecycle {
    private(set) var active = false
    private(set) var interrupted = false
    var shouldPlay: Bool { active && !interrupted }

    mutating func setActive(_ value: Bool) {
        if !value || !active { interrupted = false }
        active = value
    }

    mutating func interruptionBegan() { interrupted = true }

    mutating func interruptionEnded() { interrupted = false }
}
