// Convert an analog movement stick into DS directions. Separate press/release
// thresholds prevent drift and flicker near the edge without delaying input.
nonisolated struct StickDirections {
    private var horizontal = 0
    private var vertical = 0

    mutating func clear() {
        horizontal = 0
        vertical = 0
    }

    mutating func update(x: Float, y: Float) -> UInt16 {
        horizontal = direction(x, previous: horizontal)
        vertical = direction(y, previous: vertical)
        var mask: UInt16 = 0
        if horizontal < 0 { mask |= 1 << 6 }
        if horizontal > 0 { mask |= 1 << 7 }
        if vertical < 0 { mask |= 1 << 5 }
        if vertical > 0 { mask |= 1 << 4 }
        return mask
    }

    private func direction(_ value: Float, previous: Int) -> Int {
        guard value.isFinite else { return 0 }
        if value >= 0.45 { return 1 }
        if value <= -0.45 { return -1 }
        if previous > 0 && value > 0.30 { return 1 }
        if previous < 0 && value < -0.30 { return -1 }
        return 0
    }
}
