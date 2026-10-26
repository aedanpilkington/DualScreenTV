import Foundation

// Adapt rendering quality, never guest clocks or audio pitch. Conservative
// headroom and asymmetric cooldown avoid oscillation and repeated resize stalls.
nonisolated struct DSResolutionController {
    private(set) var factor = 1
    private var maximum = 0
    private var automatic = false
    private var lastSample: Double?
    private var windowStart = 0.0
    private var windowTicks = 0
    private var windowWork = 0.0
    private var nextChange = 0.0
    private var stableSince: Double?
    private var lastIncrease: Double?
    private var nextIncrease = 0.0

    mutating func configure(maximum: Int, automatic: Bool) -> Int {
        let upper = min(8, max(1, maximum))
        if self.maximum != upper || self.automatic != automatic {
            self.maximum = upper; self.automatic = automatic
            factor = automatic ? min(3, upper) : upper
            resetSamples()
        }
        return factor
    }
    mutating func resetSamples() {
        lastSample = nil; windowTicks = 0; windowWork = 0
        stableSince = nil; nextChange = 0; lastIncrease = nil; nextIncrease = 0
    }
    mutating func observe(now: Double, ticks: Int, workSeconds: Double) {
        guard automatic, now.isFinite, workSeconds.isFinite, workSeconds >= 0, ticks > 0 else { return }
        if lastSample == nil || now - (lastSample ?? now) > 0.5 || now < (lastSample ?? now) {
            windowStart = now; windowTicks = 0; windowWork = 0; stableSince = nil
        }
        lastSample = now
        windowTicks += ticks; windowWork += workSeconds
        let duration = now - windowStart
        guard windowTicks >= 15, duration >= 1.0 else { return }
        let perTick = windowWork / Double(windowTicks)
        let rate = Double(windowTicks) / duration
        defer { windowStart = now; windowTicks = 0; windowWork = 0 }
        guard now >= nextChange else { return }
        if perTick > 0.015 || rate < 55 {
            stableSince = nil
            guard factor > 1 else { return }
            if lastIncrease != nil { nextIncrease = now + 45 }
            lastIncrease = nil
            let ratio = sqrt(0.011 / max(perTick, 0.001))
            factor = max(1, min(factor - 1, Int(Double(factor) * ratio)))
            nextChange = now + 1.5
            return
        }
        // Leave several ms for presentation, audio and system scheduling. A
        // native-size guest-CPU allowance permits recovery from 1x. At higher
        // scales, estimate pixel cost conservatively. Failed increases back off.
        let fixed = factor == 1 ? min(0.006, perTick * 0.8) : min(0.003, perTick)
        let projected = fixed + (perTick - fixed) * pow(Double(factor + 1) / Double(factor), 2)
        guard factor < maximum, now >= nextIncrease, rate >= 58, projected < 0.012 else { stableSince = nil; return }
        if stableSince == nil { stableSince = now }
        if now - (stableSince ?? now) >= 8 {
            factor += 1; nextChange = now + 3; lastIncrease = now; stableSince = nil
        }
    }
}
