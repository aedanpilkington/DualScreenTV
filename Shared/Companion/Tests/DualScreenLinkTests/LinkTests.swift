import XCTest
import Network
@testable import DualScreenLink

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return storage } set { lock.lock(); defer { lock.unlock() }; storage = newValue } }
}
final class LinkTests: XCTestCase {
    func until(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("Timed out waiting for companion state"); throw LinkError.invalidPacket
    }
    func testProtocolRejectsInvalidHeadersAndTouches() throws {
        let frame = LinkPacket(kind: .frame, sequence: 42, timestamp: 12345, body: Data(count: LinkPacket.frameBytes))
        let parsed = try LinkPacket.header(Data(frame.encoded.prefix(24)))
        XCTAssertEqual(parsed.0, .frame); XCTAssertEqual(parsed.1, 196608); XCTAssertEqual(parsed.2, 42); XCTAssertEqual(parsed.3, 12345)
        for index in [0, 4, 5, 6, 7, 8, 9, 10, 11] {
            var invalid = Data(frame.encoded.prefix(24)); invalid[index] = 255
            XCTAssertThrowsError(try LinkPacket.header(invalid))
        }
        for length in 0..<24 { XCTAssertThrowsError(try LinkPacket.header(Data(count: length))) }
        XCTAssertThrowsError(try LinkTouch(Data([2, 1, 0, 0, 0])))
        XCTAssertThrowsError(try LinkTouch(Data([0, 0, 0, 0, 0])))
        var touch = LinkTouchState()
        XCTAssertThrowsError(try touch.apply(LinkTouch(phase: .move, x: 1, y: 1)))
        try touch.apply(LinkTouch(phase: .down, x: 255, y: 191)); XCTAssertTrue(touch.pressed)
        try touch.apply(LinkTouch(phase: .up, x: 255, y: 191)); XCTAssertFalse(touch.pressed)
    }
    func testDisplayModesAndInverseTouchMapping() {
        let size = CGSize(width: 1200, height: 600)
        let original = LinkViewport(size: size, mode: .original, zoom: 1.08)
        XCTAssertEqual(original.rect, CGRect(x: 200, y: 0, width: 800, height: 600))
        XCTAssertNil(original.pixel(at: CGPoint(x: 100, y: 300), starting: true))
        XCTAssertEqual(original.pixel(at: CGPoint(x: 600, y: 300))?.0, 128)
        XCTAssertEqual(original.pixel(at: CGPoint(x: 600, y: 300))?.1, 96)
        let fill = LinkViewport(size: size, mode: .fill, zoom: 1)
        XCTAssertEqual(fill.rect, CGRect(x: 0, y: -150, width: 1200, height: 900))
        XCTAssertEqual(fill.pixel(at: .zero)?.1, 32) // Cropped top maps to the visible DS row.
        let stretch = LinkViewport(size: size, mode: .stretch, zoom: 1)
        XCTAssertEqual(stretch.rect, CGRect(origin: .zero, size: size))
        XCTAssertEqual(stretch.pixel(at: CGPoint(x: 600, y: 150))?.1, 48)
        let overscan = LinkViewport(size: size, mode: .overscan, zoom: 1.1)
        XCTAssertEqual(overscan.rect.width, 880, accuracy: 0.001)
        for mode in LinkDisplayMode.allCases {
            let viewport = LinkViewport(size: size, mode: mode, zoom: 1.08)
            for (x, y) in [(0, 0), (255, 191), (128, 96)] {
                let point = CGPoint(x: viewport.rect.minX + (Double(x) + 0.5) * viewport.rect.width / 256,
                                    y: viewport.rect.minY + (Double(y) + 0.5) * viewport.rect.height / 192)
                XCTAssertEqual(viewport.pixel(at: point)?.0, UInt16(x))
                XCTAssertEqual(viewport.pixel(at: point)?.1, UInt16(y))
            }
        }
        XCTAssertNil(LinkViewport(size: .zero, mode: .fill, zoom: 1).pixel(at: .zero))
    }
    func testFastPixelCompressionAndCorruption() throws {
        let pixels = LinkTestImage.make(sequence: 42, touch: LinkTouchState())
        let packet = LinkPixels.packet(pixels, sequence: 42)
        XCTAssertEqual(packet.kind, .compressedFrame)
        XCTAssertLessThan(packet.body.count, pixels.count / 4)
        XCTAssertEqual(try LinkPixels.decode(packet), pixels)
        XCTAssertEqual(try LinkPixels.decode(LinkPacket(kind: .frame, body: pixels)), pixels)
        XCTAssertThrowsError(try LinkPixels.decode(LinkPacket(kind: .compressedFrame, body: Data([1, 2, 3]))))
        let oversized = LinkPixels.packet(Data(count: LinkPacket.frameBytes + 1), sequence: 0)
        XCTAssertThrowsError(try LinkPixels.decode(oversized))
    }
    func testConnectionFramesTouchDisconnectAndReconnect() async throws {
        let state = Box(LinkHostStatus())
        let host = LinkHost { state.value = $0 }; host.start()
        defer { host.stop() }
        try await until { state.value.port != nil }
        let device = LinkDevice(id: "test", name: "Loopback", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: state.value.port!)!))
        let menuState = Box(LinkMenuState())
        let connected = Box(false)
        let client = LinkClient(devices: { _ in }, status: { _, value in connected.value = value }, menu: { menuState.value = $0 })
        defer { client.stop() }
        let wrong = host.pairingCode == "000000" ? "111111" : "000000"
        client.connect(device, code: wrong)
        try await until { state.value.message.contains("Incorrect") }
        XCTAssertFalse(connected.value)
        client.connect(device, code: host.pairingCode)
        try await until { connected.value && client.frames.counts.received >= 15 }
        XCTAssertGreaterThan(client.frames.counts.replaced, 0) // No display consumer, still bounded to one frame.
        let latest = client.frames.take()!
        XCTAssertEqual(latest.image.width, 256); XCTAssertEqual(latest.image.height, 192)
        XCTAssertNil(client.frames.take())
        XCTAssertNotNil(client.frames.latest) // Retain the paused image across a canvas/layout rebuild.
        host.publishMenu(LinkMenuState(active: true, paused: true, dualScreen: true, volume: 40))
        try await until { menuState.value.active && menuState.value.volume == 40 }
        client.menu(LinkMenuCommand(.volume, value: 30))
        let receivedCommand = Box(false)
        try await until {
            let commands = host.takeMenuCommands()
            if commands.contains(where: { $0.action == .volume && $0.value == 30 }) { receivedCommand.value = true }
            return receivedCommand.value
        }
        XCTAssertThrowsError(try LinkMenuCommand(Data([6, 101])))
        XCTAssertThrowsError(try LinkMenuCommand(Data([1, 1])))
        XCTAssertThrowsError(try LinkMenuCommand(Data([255, 0])))
        XCTAssertThrowsError(try LinkMenuState(Data([1, 1, 1, 101, 0])))
        client.analog(x: -16384, y: 32767)
        try await until { host.latestAnalog.x == -16384 && host.latestAnalog.y == 32767 }
        client.analog(x: 0, y: 0)
        try await until { host.latestAnalog.x == 0 && host.latestAnalog.y == 0 }
        client.analog(x: 32767, y: -32767)
        try await until { host.latestAnalog.x == 32767 }
        client.buttons((1 << 8) | (1 << 4))
        try await until { host.latestButtons == (1 << 8) | (1 << 4) }
        client.buttons(1 << 8)
        try await until { host.latestButtons == 1 << 8 }
        client.touch(LinkTouch(phase: .down, x: 45, y: 67))
        try await until { host.latestTouch.pressed && host.latestTouch.x == 45 }
        client.touch(LinkTouch(phase: .move, x: 100, y: 120))
        try await until { host.latestTouch.x == 100 }
        client.touch(LinkTouch(phase: .up, x: 100, y: 120))
        try await until { !host.latestTouch.pressed }
        client.touch(LinkTouch(phase: .down, x: 10, y: 20))
        try await until { host.latestTouch.pressed }
        client.disconnect()
        try await until { !host.latestTouch.pressed && host.latestButtons == 0 && host.latestAnalog.x == 0 && host.latestAnalog.y == 0 && !connected.value }
        client.reconnect()
        try await until { connected.value && client.frames.counts.received > 2 }
        client.touch(LinkTouch(phase: .down, x: 20, y: 30))
        try await until { host.latestTouch.pressed }
        client.touch(LinkTouch(phase: .move, x: 256, y: 30))
        try await until { !connected.value && !host.latestTouch.pressed }
    }
    func testGameSnapshotReplacementPauseAndReturnToPreview() async throws {
        let state = Box(LinkHostStatus())
        let host = LinkHost { state.value = $0 }; host.start(); defer { host.stop() }
        try await until { state.value.port != nil }
        let connected = Box(false)
        let client = LinkClient(devices: { _ in }, status: { _, value in connected.value = value })
        defer { client.stop() }
        client.connect(LinkDevice(id: "game", name: "Game", endpoint: .hostPort(host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: state.value.port!)!)), code: host.pairingCode)
        try await until { connected.value && host.wantsGameFrames }
        // A burst of emulator frames replaces one slot; only its newest is sent.
        for value in UInt8(1)...200 { host.publishGameFrame(Data(repeating: value, count: LinkPacket.frameBytes)) }
        try await until {
            guard let frame = client.frames.take(), let bytes = frame.image.dataProvider?.data else { return false }
            return (bytes as Data).first == 200
        }
        // Pausing leaves the last screen displayed; no duplicate frames accumulate.
        try await Task.sleep(nanoseconds: 150_000_000)
        let count = client.frames.counts.received
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(client.frames.counts.received, count)
        XCTAssertTrue(connected.value)
        host.endGame()
        try await until { client.frames.counts.received > count + 2 }
        XCTAssertTrue(connected.value) // Returning to the library preserves pairing.
    }
    func testFrameBackpressureAndOneSession() async throws {
        let state = Box(LinkHostStatus()), received = Box(0), sequence = Box(UInt32(0))
        let host = LinkHost { state.value = $0 }; host.start(); defer { host.stop() }
        try await until { state.value.port != nil }
        let queue = DispatchQueue(label: "LinkTests.Raw")
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: state.value.port!)!)
        let peer = LinkConnection(NWConnection(to: endpoint, using: .tcp), queue: queue)
        queue.async {
            peer.ready = { peer.send(LinkPacket(kind: .hello, body: Data(host.pairingCode.utf8))) }
            peer.received = { packet in if packet.kind == .frame || packet.kind == .compressedFrame { received.value += 1; if received.value == 1 { sequence.value = packet.sequence } } }
            peer.start()
        }
        defer { queue.async { peer.close() } }
        try await until { received.value == 2 }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(received.value, 2) // Sender cannot pile up TCP frames without a display ACK.
        let secondConnected = Box(false), secondMessage = Box("")
        let second = LinkClient(devices: { _ in }, status: { message, connected in secondMessage.value = message; secondConnected.value = connected })
        defer { second.stop() }
        second.connect(LinkDevice(id: "second", name: "Loopback", endpoint: endpoint), code: host.pairingCode)
        try await until { secondMessage.value.contains("reconnect") }
        XCTAssertFalse(secondConnected.value)
        queue.async { peer.send(LinkPacket(kind: .frameAck, sequence: sequence.value)) }
        try await until { received.value == 3 }
    }
}
