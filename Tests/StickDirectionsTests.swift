@main
struct StickDirectionsTests {
    static func main() {
        var stick = StickDirections()
        let up: UInt16 = 1 << 4, down: UInt16 = 1 << 5
        let left: UInt16 = 1 << 6, right: UInt16 = 1 << 7
        assert(stick.update(x: 0.2, y: -0.2) == 0)
        assert(stick.update(x: 1, y: 0) == right)
        assert(stick.update(x: 0.4, y: 0) == right)
        assert(stick.update(x: 0.3, y: 0) == 0)
        assert(stick.update(x: 0.4, y: 0) == 0)
        assert(stick.update(x: -1, y: 1) == left | up)
        assert(stick.update(x: 1, y: -1) == right | down)
        assert(stick.update(x: 0, y: 0) == 0)
        assert(stick.update(x: -1, y: -1) == left | down)
        assert(stick.update(x: .nan, y: .infinity) == 0)
        assert(stick.update(x: 1, y: 1) == right | up)
        stick.clear()
        assert(stick.update(x: 0.4, y: 0.4) == 0)
        print("Stick directions: drift, hysteresis, diagonals, reversal and reset passed")
    }
}
