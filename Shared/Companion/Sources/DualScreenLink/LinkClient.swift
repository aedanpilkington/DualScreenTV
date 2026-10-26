import Foundation
import Network
import CoreGraphics

nonisolated struct LinkDevice: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}
nonisolated struct LinkFrame: @unchecked Sendable {
    let image: CGImage
    let sequence: UInt32
    let timestamp: UInt64
}
// Single-slot display mailbox: a slow display replaces, rather than queues, frames.
nonisolated final class LinkFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: LinkFrame?
    private var mostRecent: LinkFrame?
    var latest: LinkFrame? { lock.lock(); defer { lock.unlock() }; return mostRecent }
    private var received = 0, replaced = 0
    func put(_ value: LinkFrame) { lock.lock(); defer { lock.unlock() }; if frame != nil { replaced += 1 }; frame = value; mostRecent = value; received += 1 }
    func take() -> LinkFrame? { lock.lock(); defer { lock.unlock() }; let value = frame; frame = nil; return value }
    var counts: (received: Int, replaced: Int) { lock.lock(); defer { lock.unlock() }; return (received, replaced) }
    func clear() { lock.lock(); defer { lock.unlock() }; frame = nil; mostRecent = nil; received = 0; replaced = 0 }
}
nonisolated final class LinkClient: @unchecked Sendable {
    let frames = LinkFrameMailbox()
    private let queue = DispatchQueue(label: "DualScreenTV.CompanionClient", qos: .userInitiated)
    private var browser: NWBrowser?
    private var link: LinkConnection?
    private var timer: DispatchSourceTimer?
    private var connected = false
    private var pendingMove: LinkTouch?
    private var pairedDeviceID: String?
    private var reconnectGeneration = 0
    private var reconnectAllowed = false
    private var reconnectAttempts = 0
    private var rememberedDevice: LinkDevice?
    private var rememberedCode = ""
    private var ticks = 0
    private var lastSequence: UInt32?
    let devicesChanged: @Sendable ([LinkDevice]) -> Void
    let statusChanged: @Sendable (String, Bool) -> Void
    let menuChanged: @Sendable (LinkMenuState) -> Void
    init(devices: @escaping @Sendable ([LinkDevice]) -> Void, status: @escaping @Sendable (String, Bool) -> Void, menu: @escaping @Sendable (LinkMenuState) -> Void = { _ in }) {
        devicesChanged = devices; statusChanged = status; menuChanged = menu
    }
    func browse() { queue.async { [self] in
        guard browser == nil else { return }
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = false
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.disableAckStretching = true
        let browser = NWBrowser(for: .bonjour(type: LinkConnection.service, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> LinkDevice? in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                return LinkDevice(id: name + type + domain, name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            self?.devicesChanged(Array(Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.statusChanged("Discovery failed: \(error.localizedDescription)", false) }
        }
        browser.start(queue: queue)
    } }
    func connect(_ device: LinkDevice, code: String) { queue.async { [self] in
        rememberedDevice = device; rememberedCode = code
        disconnectOnQueue(allowReconnect: true); frames.clear(); lastSequence = nil
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { statusChanged("Enter the six-digit code on Apple TV", false); return }
        statusChanged("Connecting to \(device.name)…", false)
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = false
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.disableAckStretching = true
        let link = LinkConnection(NWConnection(to: device.endpoint, using: parameters), queue: queue); self.link = link
        link.ready = { [weak link] in link?.send(LinkPacket(kind: .hello, body: Data(code.utf8))) }
        link.received = { [weak self] packet in try self?.receive(packet) }
        link.ended = { [weak self] reason in
            guard let self else { return }
            self.timer?.cancel(); self.timer = nil; self.link = nil; self.connected = false
            self.pendingMove = nil; self.frames.clear(); self.menuChanged(LinkMenuState()); self.statusChanged("\(reason). Select a device to reconnect.", false)
            let retryable = self.pairedDeviceID == self.rememberedDevice?.id && !["Incorrect", "Too many", "Invalid", "Unsupported", "pairing"].contains { reason.localizedCaseInsensitiveContains($0) }
            if self.reconnectAllowed, retryable, self.reconnectAttempts < 3, let device = self.rememberedDevice {
                self.reconnectAttempts += 1
                let delay = Double(1 << (self.reconnectAttempts - 1))
                let code = self.rememberedCode
                let generation = self.reconnectGeneration
                self.statusChanged("Connection lost — reconnecting…", false)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.reconnectGeneration == generation, self.reconnectAllowed, self.link == nil, !self.connected else { return }
                    self.connect(device, code: code)
                }
            }
        }
        link.start()
    } }
    private func receive(_ packet: LinkPacket) throws {
        if !connected {
            guard packet.kind == .welcome, packet.body == LinkPacket.descriptor else { throw LinkError.invalidPacket }
            connected = true; pairedDeviceID = rememberedDevice?.id; reconnectAttempts = 0; statusChanged("Connected to Apple TV", true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            ticks = 0
            timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.ticks += 1
                if let move = self.pendingMove { self.pendingMove = nil; self.link?.send(LinkPacket(kind: .touch, body: move.encoded)) }
                if self.ticks % 60 == 0 { self.link?.send(LinkPacket(kind: .ping)) }
            }
            self.timer = timer; timer.resume(); return
        }
        switch packet.kind {
        case .menuState: menuChanged(try LinkMenuState(packet.body))
        case .frame, .compressedFrame:
            if let lastSequence, packet.sequence != lastSequence &+ 1 { throw LinkError.invalidPacket }
            lastSequence = packet.sequence
            let pixels = try LinkPixels.decode(packet)
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: 256, height: 192, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw LinkError.invalidPacket }
            frames.put(LinkFrame(image: image, sequence: packet.sequence, timestamp: packet.timestamp))
            link?.send(LinkPacket(kind: .frameAck, sequence: packet.sequence))
        case .pong: break
        default: throw LinkError.invalidPacket
        }
    }
    func touch(_ touch: LinkTouch) { queue.async { [self] in
        guard connected else { return }
        if touch.phase == .move { pendingMove = touch }
        else { pendingMove = nil; link?.send(LinkPacket(kind: .touch, body: touch.encoded)) }
    } }
    func menu(_ command: LinkMenuCommand) { queue.async { [self] in
        guard connected else { return }
        link?.send(LinkPacket(kind: .menuCommand, body: command.encoded))
    } }
    func analog(x: Int16, y: Int16) { queue.async { [self] in
        guard connected else { return }
        var body = Data(); body.appendBE(x); body.appendBE(y)
        link?.send(LinkPacket(kind: .analog, body: body))
    } }
    func buttons(_ buttons: UInt16) { queue.async { [self] in
        guard connected else { return }
        var body = Data(); body.appendBE(buttons & 0x0fff)
        link?.send(LinkPacket(kind: .buttons, body: body))
    } }
    func reconnect() { queue.async { [self] in
        guard let device = rememberedDevice, !rememberedCode.isEmpty else { return }
        reconnectAttempts = 0
        connect(device, code: rememberedCode)
    } }
    func disconnect() { queue.async { [self] in disconnectOnQueue() } }
    func stop() { queue.async { [self] in disconnectOnQueue(); browser?.cancel(); browser = nil; devicesChanged([]) } }
    private func disconnectOnQueue(allowReconnect: Bool = false) {
        reconnectGeneration += 1
        // Closing an old connection is deliberate; its callback must not
        // schedule a retry that could outlive a later pairing attempt.
        reconnectAllowed = false
        timer?.cancel(); timer = nil; pendingMove = nil
        link?.close(); link = nil; connected = false
        frames.clear(); menuChanged(LinkMenuState())
        reconnectAllowed = allowReconnect
    }
}
