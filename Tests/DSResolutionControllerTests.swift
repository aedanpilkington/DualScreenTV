import Foundation
@main struct DSResolutionControllerTests {
    static func main() {
        var controller = DSResolutionController()
        assert(controller.configure(maximum: 8, automatic: true) == 3)
        // Sustained overload lowers rendering scale while keeping guest timing.
        for n in 0..<60 { controller.observe(now: Double(n)/40, ticks: 1, workSeconds: 0.024) }
        assert(controller.factor < 3)
        let lower = controller.factor
        // A brief fast interval must not immediately raise quality again.
        for n in 90..<150 { controller.observe(now: Double(n)/60, ticks: 1, workSeconds: 0.004) }
        assert(controller.factor == lower)
        for n in 150..<900 { controller.observe(now: Double(n)/60, ticks: 1, workSeconds: 0.004) }
        assert(controller.factor > lower && controller.factor <= 8)
        assert(controller.configure(maximum: 4, automatic: false) == 4)
        for n in 0..<100 { controller.observe(now: Double(n), ticks: 1, workSeconds: 1) }
        assert(controller.factor == 4)
        assert(controller.configure(maximum: 1, automatic: true) == 1)
        controller.observe(now: .nan, ticks: 1, workSeconds: 1)
        controller.observe(now: 1, ticks: 0, workSeconds: 1)
        assert(controller.factor == 1)
        // Pause/resume must not treat idle time as slow emulation.
        _ = controller.configure(maximum: 4, automatic: true)
        controller.observe(now: 0, ticks: 1, workSeconds: 0.006)
        controller.observe(now: 20, ticks: 1, workSeconds: 0.006)
        assert(controller.factor == 3)
        // Guest CPU/capture cost does not scale quadratically with pixels.
        // A native fallback must recover to 2x when a normal scene has headroom.
        var recovery = DSResolutionController()
        _ = recovery.configure(maximum: 4, automatic: true)
        for n in 0..<180 { recovery.observe(now: Double(n)/40, ticks: 1, workSeconds: 0.030) }
        assert(recovery.factor == 1)
        for n in 300..<1200 { recovery.observe(now: Double(n)/60, ticks: 1, workSeconds: 0.0065) }
        assert(recovery.factor >= 2)
        var scheduling = DSResolutionController()
        _ = scheduling.configure(maximum: 4, automatic: true)
        for n in 0..<90 { scheduling.observe(now: Double(n)/45, ticks: 1, workSeconds: 0.010) }
        assert(scheduling.factor < 3)
        var renderHeadroom = DSResolutionController()
        _ = renderHeadroom.configure(maximum: 8, automatic: true)
        for n in 0..<1200 { renderHeadroom.observe(now: Double(n)/60, ticks: 1, workSeconds: 0.0085) }
        assert(renderHeadroom.factor == 3)
        var failedProbe = DSResolutionController()
        _ = failedProbe.configure(maximum: 2, automatic: true)
        var clock = 0.0
        func advance(_ seconds: Int, cost: Double) {
            for _ in 0..<(seconds * 60) {
                clock += 1.0 / 60
                failedProbe.observe(now: clock, ticks: 1, workSeconds: cost)
            }
        }
        advance(3, cost: 0.025)
        assert(failedProbe.factor == 1)
        advance(15, cost: 0.0065)
        assert(failedProbe.factor == 2)
        advance(3, cost: 0.025)
        assert(failedProbe.factor == 1)
        advance(25, cost: 0.0065)
        assert(failedProbe.factor == 1)
        advance(40, cost: 0.0065)
        assert(failedProbe.factor == 2)
        print("DS resolution: overload reduction, gradual recovery, fixed mode, bounds and pause passed")
    }
}
