import Foundation

nonisolated enum LinkError: Error { case invalidPacket }
nonisolated enum LinkKind: UInt8 { case hello = 1, welcome, frame, touch, ping, pong, frameAck, compressedFrame, buttons, analog, menuCommand, menuState }
nonisolated struct LinkPacket: Sendable {
    static let headerSize = 24
    static let width = 256, height = 192, frameBytes = width * height * 4
    let kind: LinkKind
    var sequence: UInt32 = 0
    var timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds / 1000
    var body = Data()
    var encoded: Data {
        var data = Data([0x44, 0x53, 0x54, 0x56, 1, kind.rawValue, 0, 0])
        data.appendBE(UInt32(body.count)); data.appendBE(sequence); data.appendBE(timestamp)
        data.append(body); return data
    }
    static func header(_ bytes: Data) throws -> (LinkKind, Int, UInt32, UInt64) {
        guard bytes.count == headerSize, Array(bytes.prefix(5)) == [0x44, 0x53, 0x54, 0x56, 1],
              bytes[6] == 0, bytes[7] == 0, let kind = LinkKind(rawValue: bytes[5]) else { throw LinkError.invalidPacket }
        let length = Int(bytes.readBE(8, count: 4))
        let expected: Int
        switch kind { case .hello: expected = 6; case .welcome: expected = 6
        case .compressedFrame:
            guard length > 0, length <= frameBytes else { throw LinkError.invalidPacket }
            expected = length
        case .menuCommand: expected = 2
        case .menuState: expected = 5
        case .analog: expected = 4
        case .buttons: expected = 2
        case .frame: expected = frameBytes; case .touch: expected = 5
        case .ping, .pong, .frameAck: expected = 0 }
        guard length == expected else { throw LinkError.invalidPacket }
        return (kind, length, UInt32(bytes.readBE(12, count: 4)), bytes.readBE(16, count: 8))
    }
    static let descriptor = Data([1, 0, 0, 192, 1, 60]) // 256×192, RGBA8, 60 Hz
}
nonisolated extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var number = value.bigEndian; Swift.withUnsafeBytes(of: &number) { append(contentsOf: $0) }
    }
    func readBE(_ offset: Int, count: Int) -> UInt64 {
        (offset..<(offset + count)).reduce(0) { ($0 << 8) | UInt64(self[$1]) }
    }
}
nonisolated enum LinkTouchPhase: UInt8, Sendable { case down = 1, move, up }
nonisolated struct LinkTouch: Sendable, Equatable {
    let phase: LinkTouchPhase
    let x: UInt16, y: UInt16
    var encoded: Data { var data = Data([phase.rawValue]); data.appendBE(x); data.appendBE(y); return data }
    init(phase: LinkTouchPhase, x: UInt16, y: UInt16) { self.phase = phase; self.x = x; self.y = y }
    init(_ body: Data) throws {
        guard body.count == 5, let phase = LinkTouchPhase(rawValue: body[0]) else { throw LinkError.invalidPacket }
        let x = UInt16(body.readBE(1, count: 2)), y = UInt16(body.readBE(3, count: 2))
        guard x < 256, y < 192 else { throw LinkError.invalidPacket }
        self.init(phase: phase, x: x, y: y)
    }
}
nonisolated struct LinkTouchState: Sendable, Equatable {
    var pressed = false
    var x: UInt16 = 0, y: UInt16 = 0
    mutating func apply(_ touch: LinkTouch) throws {
        guard touch.phase != .move || pressed else { throw LinkError.invalidPacket }
        pressed = touch.phase != .up; x = touch.x; y = touch.y
    }
}
nonisolated enum LinkTestImage {
    private static let background: Data = {
        var data = Data(count: LinkPacket.frameBytes)
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for y in 0..<192 { for x in 0..<256 {
                pixels[y * 256 + x] = (UInt32((x / 8) * 8) | (UInt32((y / 8) * 8) << 8) | 0xff500000).littleEndian
            } }
        }
        return data
    }()
    static func make(sequence: UInt32, touch: LinkTouchState) -> Data {
        // Copy-on-write background plus a small moving marker, rather than
        // regenerating every pixel at every tick (especially costly in Debug).
        var data = background
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            let marker = Int(sequence % 256)
            for y in 0..<192 { for x in max(0, marker - 4)...min(255, marker + 4) {
                pixels[y * 256 + x] = UInt32(0xffff8040).littleEndian
            } }
            if touch.pressed {
                let tx = Int(touch.x), ty = Int(touch.y)
                for y in 0..<192 { for x in max(0, tx - 2)...min(255, tx + 2) { pixels[y * 256 + x] = 0xffffffff } }
                for y in max(0, ty - 2)...min(191, ty + 2) { for x in 0..<256 { pixels[y * 256 + x] = 0xffffffff } }
            }
        }
        return data
    }
}


nonisolated enum LinkMenuAction: UInt8, Sendable {
    case pause = 1, resume, swapScreens, openSettings, returnToLibrary, volume, saveState, loadState
}
nonisolated struct LinkMenuCommand: Sendable {
    let action: LinkMenuAction
    var value: UInt8 = 0
    var encoded: Data { Data([action.rawValue, value]) }
    init(_ action: LinkMenuAction, value: UInt8 = 0) { self.action = action; self.value = value }
    init(_ data: Data) throws {
        guard data.count == 2, let action = LinkMenuAction(rawValue: data[0]),
              action == .volume ? data[1] <= 100 : ((action == .saveState || action == .loadState) ? (1...10).contains(data[1]) : data[1] == 0) else { throw LinkError.invalidPacket }
        self.action = action; value = data[1]
    }
}
nonisolated struct LinkMenuState: Sendable, Equatable {
    var active = false
    var paused = false
    var dualScreen = false
    var volume: UInt8 = 100
    var bottomOnTV = false
    var encoded: Data { Data([active ? 1 : 0, paused ? 1 : 0, dualScreen ? 1 : 0, volume, bottomOnTV ? 1 : 0]) }
    init(active: Bool = false, paused: Bool = false, dualScreen: Bool = false, volume: UInt8 = 100, bottomOnTV: Bool = false) {
        self.active = active; self.paused = paused; self.dualScreen = dualScreen
        self.volume = volume; self.bottomOnTV = bottomOnTV
    }
    init(_ data: Data) throws {
        guard data.count == 5, data[0] <= 1, data[1] <= 1, data[2] <= 1, data[3] <= 100, data[4] <= 1 else { throw LinkError.invalidPacket }
        active = data[0] == 1; paused = data[1] == 1; dualScreen = data[2] == 1
        volume = data[3]; bottomOnTV = data[4] == 1
    }
}
