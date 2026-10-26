import Foundation

// Main-thread scheduler. Native DS retains one-frame ticks at 1x; high-resolution
// DS and 3DS can catch up at most two ticks after timer jitter. Other speeds
// accumulate fractional frames using libretro timing and a monotonic clock.
// Neither overdue work nor unlimited mode can build an unbounded queue.
nonisolated struct FramePacer {
    private var previous: Double?
    private var credit = 0.0
    mutating func deferFrames(_ frames: Int, debtLimit: Int = 2) { credit = min(Double(min(4, max(2, debtLimit))), credit + Double(max(0, frames))) }
    mutating func reset() { previous = nil; credit = 0 }
    mutating func framesDue(now: Double, fps: Double, speed: Double, catchUp: Bool = false, debtLimit: Int = 2) -> Int {
        guard now.isFinite, fps.isFinite, fps > 0, speed.isFinite, speed >= 0 else { reset(); return 0 }
        let elapsed = max(0, min(0.05, now - (previous ?? (now - 1 / fps))))
        previous = now
        if speed == 1 && !catchUp { credit = 0; return 1 }
        if speed == 0 { credit = 0; return 8 }
        credit = min(speed == 1 ? Double(min(4, max(2, debtLimit))) : 8, credit + elapsed * fps * speed)
        let frames = speed == 1 ? min(2, Int(credit + 0.000001)) : Int(credit + 0.000001)
        credit = max(0, credit - Double(frames))
        return frames
    }
}
