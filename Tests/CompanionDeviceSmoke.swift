// Build with Shared/Companion/Sources/DualScreenLink/*.swift, then pass the
// six-digit code from the Apple TV Companion screen. No fixed host/IP needed.
import Foundation

nonisolated final class SmokeState: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [LinkDevice] = []
    private var active = false
    func devices(_ value: [LinkDevice]) { lock.lock(); found = value; lock.unlock() }
    func status(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    var devices: [LinkDevice] { lock.lock(); defer { lock.unlock() }; return found }
    var connected: Bool { lock.lock(); defer { lock.unlock() }; return active }
}
@main struct CompanionDeviceSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the six-digit Apple TV pairing code") }
        let state = SmokeState()
        let client = LinkClient(devices: { state.devices($0) }, status: { message, connected in print(message); state.status(connected) })
        defer { client.stop() }
        client.browse()
        for _ in 0..<100 { if !state.devices.isEmpty { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        guard let device = state.devices.first else { fatalError("No Bonjour companion discovered") }
        print("Discovered: \(device.name)")
        client.connect(device, code: CommandLine.arguments[1])
        for _ in 0..<100 { if state.connected { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        guard state.connected else { fatalError("Pairing failed") }
        client.touch(LinkTouch(phase: .down, x: 123, y: 87))
        let start = DispatchTime.now().uptimeNanoseconds
        let initial = client.frames.counts.received
        for index in 0..<300 {
            if index == 100 { client.touch(LinkTouch(phase: .move, x: 200, y: 150)) }
            if index == 200 { client.touch(LinkTouch(phase: .up, x: 200, y: 150)) }
            if let frame = client.frames.take() { precondition(frame.image.width == 256 && frame.image.height == 192) }
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let count = client.frames.counts.received - initial
        print(String(format: "Received %d frames in %.2fs (%.1f FPS), mailbox replacements %d", count, elapsed, Double(count) / elapsed, client.frames.counts.replaced))
        precondition(count > 30, "Stream stalled")
        client.disconnect()
        try await Task.sleep(nanoseconds: 200_000_000)
        client.connect(device, code: CommandLine.arguments[1])
        for _ in 0..<100 { if state.connected && client.frames.counts.received > 2 { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(state.connected && client.frames.counts.received > 2, "Reconnect failed")
        print("Bonjour, pairing, native frame decode, touch transmission, disconnect and reconnect passed.")
    }
}
