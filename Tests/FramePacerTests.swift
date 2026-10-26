import Foundation

@main
struct FramePacerTests {
    static func main() {
        let fps = 59.898308
        for speed in [0.5, 1, 1.5, 2, 3, 4] {
            // Accurate 3DS clock on a slightly faster host timer must retain its
        // long-term cadence instead of overproducing audio at rounded 60 Hz.
        var exact=FramePacer();let native=268111856.0/4481136.0,host=59.898308
        var total=0;let callbacks=36000
        for index in 0..<callbacks {total += exact.framesDue(now:Double(index)/host,fps:native,speed:1,catchUp:true,debtLimit:4)}
        let elapsed=Double(callbacks-1)/host
        assert(abs(Double(total)-(1+elapsed*native))<=1)
        let scheduledAudio=Double(total-1)*(4481136.0/8192.0)
        let hardwareAudio=elapsed*(268111856.0/8192.0)
        assert(abs(scheduledAudio-hardwareAudio)<=548)
        var pacer = FramePacer()
            var frames = 0
            for tick in 0..<600 { frames += pacer.framesDue(now: Double(tick) / fps, fps: fps, speed: speed) }
            assert(abs(Double(frames) - 600 * speed) <= 1)
        }
        // A delayed 40 Hz timer must still schedule approximately 60 guest ticks.
        var catchup = FramePacer()
        var scheduled = 0
        for tick in 0..<400 {
            let due = catchup.framesDue(now: Double(tick) / 40, fps: 60, speed: 1, catchUp: true)
            assert(due <= 2)
            scheduled += due
        }
        assert(abs(scheduled - 600) <= 1)
        // Long stalls are bounded; an unexecuted tick can be retried once.
        assert(catchup.framesDue(now: 100, fps: 60, speed: 1, catchUp: true) == 2)
        catchup.deferFrames(1)
        assert(catchup.framesDue(now: 100, fps: 60, speed: 1, catchUp: true) == 1)
        catchup.reset()
        assert(catchup.framesDue(now: 200, fps: 60, speed: 1, catchUp: true) == 1)
        // Dust retains fractional debt through uneven timer delivery without
        // scheduling more than two frames in any callback.
        var dust = FramePacer()
        var now = 0.0
        var dustFrames = dust.framesDue(now: now, fps: 60, speed: 1, catchUp: true, debtLimit: 4)
        for _ in 0..<100 {
            for interval in [0.03, 0.03, 0.01, 0.01, 1.0 / 300] {
                now += interval
                let due = dust.framesDue(now: now, fps: 60, speed: 1, catchUp: true, debtLimit: 4)
                assert(due <= 2)
                dustFrames += due
            }
        }
        assert(abs(Double(dustFrames) - (now * 60 + 1)) <= 1)
        // 3DS can recover a 50 ms transient stall without discarding a tick.
        // Work per callback remains bounded to two ticks, including deferred work.
        var threeDS = FramePacer()
        assert(threeDS.framesDue(now: 0, fps: 60, speed: 1, catchUp: true, debtLimit: 4) == 1)
        assert(threeDS.framesDue(now: 0.05, fps: 60, speed: 1, catchUp: true, debtLimit: 4) == 2)
        threeDS.deferFrames(1, debtLimit: 4) // Only the first tick fit the work budget.
        assert(threeDS.framesDue(now: 0.05 + 1.0 / 60, fps: 60, speed: 1, catchUp: true, debtLimit: 4) == 2)
        assert(threeDS.framesDue(now: 0.05 + 2.0 / 60, fps: 60, speed: 1, catchUp: true, debtLimit: 4) == 2)
        assert(threeDS.framesDue(now: 0.05 + 3.0 / 60, fps: 60, speed: 1, catchUp: true, debtLimit: 4) == 1)
        var pacer = FramePacer()
        assert(pacer.framesDue(now: 0, fps: fps, speed: 0) == 8)
        assert(pacer.framesDue(now: 100, fps: fps, speed: 4) <= 8)
        pacer.reset()
        assert(pacer.framesDue(now: 1000, fps: fps, speed: 0.5) == 0)
        assert(pacer.framesDue(now: 1001, fps: fps, speed: 1) == 1)
        assert(pacer.framesDue(now: .nan, fps: fps, speed: 1) == 0)
        assert(pacer.framesDue(now: 2, fps: 0, speed: 1) == 0)
        print("Frame pacing: fractional speeds, normal tick, unlimited bounds, stalls and reset passed")
    }
}
