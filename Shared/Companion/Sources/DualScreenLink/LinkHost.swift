import Foundation
import Network

nonisolated struct LinkHostStatus: Sendable {
    var message = "Starting companion service…"
    var port: UInt16?
    var frames: UInt32 = 0
    var touch = LinkTouchState()
}
nonisolated final class LinkHost: @unchecked Sendable {
    let pairingCode = String(format: "%06u", UInt32.random(in: 0...999_999))
    private let queue = DispatchQueue(label: "DualScreenTV.CompanionHost", qos: .userInitiated)
    private var listener: NWListener?
    private var link: LinkConnection?
    private var timer: DispatchSourceTimer?
    private var authenticated = false
    private var awaitingAcks: [(sequence: UInt32, sentAt: UInt64)] = []
    private var sentAt: UInt64 = 0
    private var sequence: UInt32 = 0
    private var ticks = 0
    private var generationMS = 0.0, ackMS = 0.0
    private var attempts = 0
    private var attemptWindow = DispatchTime.now().uptimeNanoseconds
    private var state = LinkHostStatus()
    private let touchLock = NSLock()
    private var touchSnapshot = LinkTouchState()
    private var frameSnapshot: Data?
    private var gameStreaming = false
    private var connectedSnapshot = false
    private var analogSnapshot: (x: Int16, y: Int16) = (0, 0)
    var latestAnalog: (x: Int16, y: Int16) { touchLock.lock(); defer { touchLock.unlock() }; return analogSnapshot }
    private var menuSnapshot = LinkMenuState()
    private var menuCommands: [LinkMenuCommand] = []
    func takeMenuCommands() -> [LinkMenuCommand] {
        touchLock.lock(); defer { touchLock.unlock() }
        let commands = menuCommands; menuCommands.removeAll(); return commands
    }
    func publishMenu(_ state: LinkMenuState) {
        touchLock.lock()
        let changed = menuSnapshot != state
        menuSnapshot = state
        if !state.active { menuCommands.removeAll() }
        touchLock.unlock()
        guard changed else { return }
        queue.async { [self] in
            if authenticated { link?.send(LinkPacket(kind: .menuState, body: state.encoded)) }
        }
    }
    private var buttonsSnapshot: UInt16 = 0
    var latestButtons: UInt16 { touchLock.lock(); defer { touchLock.unlock() }; return buttonsSnapshot }
    var wantsGameFrames: Bool { touchLock.lock(); defer { touchLock.unlock() }; return connectedSnapshot }
    func publishGameFrame(_ pixels: Data) {
        guard pixels.count == LinkPacket.frameBytes else { return }
        touchLock.lock(); frameSnapshot = pixels; gameStreaming = true; touchLock.unlock()
    }
    func endGame() { touchLock.lock(); frameSnapshot = nil; gameStreaming = false; touchLock.unlock() }
    private func nextPixels() -> Data? {
        touchLock.lock()
        if gameStreaming {
            let pixels = frameSnapshot; frameSnapshot = nil
            touchLock.unlock(); return pixels
        }
        let touch = touchSnapshot
        touchLock.unlock()
        return LinkTestImage.make(sequence: sequence &+ 1, touch: touch)
    }
    let changed: @Sendable (LinkHostStatus) -> Void
    init(changed: @escaping @Sendable (LinkHostStatus) -> Void) { self.changed = changed }
    // The main-thread emulator reads input and replaces one owned frame snapshot.
    var latestTouch: LinkTouchState { touchLock.lock(); defer { touchLock.unlock() }; return touchSnapshot }
    private func publishTouch() { touchLock.lock(); touchSnapshot = state.touch; touchLock.unlock() }
    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp; parameters.includePeerToPeer = false
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
                (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.disableAckStretching = true
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                var name = ProcessInfo.processInfo.hostName + " · DualScreenTV"
                while name.utf8.count > 63 { name.removeLast() }
                listener.service = NWListener.Service(name: name, type: LinkConnection.service,
                    txtRecord: Data([9]) + Data("version=1".utf8) + Data([9]) + Data("mode=game".utf8))
                listener.stateUpdateHandler = { [weak self] status in
                    guard let self else { return }
                    if case .ready = status { self.state.port = self.listener?.port?.rawValue; self.state.message = "Ready — select this Apple TV on your iPad"; self.changed(self.state) }
                    if case .failed(let error) = status { self.stopOnQueue(); self.state.message = error.localizedDescription; self.changed(self.state) }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            } catch { state.message = error.localizedDescription; changed(state) }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard link == nil else { connection.cancel(); return }
        let link = LinkConnection(connection, queue: queue); self.link = link
        state.message = "Waiting for pairing code…"; changed(state)
        link.received = { [weak self] packet in try self?.receive(packet) }
        link.ended = { [weak self] reason in
            guard let self else { return }
            self.touchLock.lock(); self.connectedSnapshot = false; self.buttonsSnapshot = 0; self.analogSnapshot = (0, 0); self.menuCommands.removeAll(); self.touchLock.unlock()
            self.link = nil; self.authenticated = false; self.awaitingAcks.removeAll()
            self.timer?.cancel(); self.timer = nil
            self.state.touch = LinkTouchState(); self.publishTouch()
            self.state.message = "\(reason). Ready to reconnect."; self.changed(self.state)
        }
        link.start()
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak link] in
            if let self, self.link === link, !self.authenticated { link?.close("Pairing timed out") }
        }
    }
    private func receive(_ packet: LinkPacket) throws {
        guard authenticated else {
            guard packet.kind == .hello else { throw LinkError.invalidPacket }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - attemptWindow >= 60_000_000_000 { attempts = 0; attemptWindow = now }
            guard attempts < 5 else { link?.close("Too many pairing attempts; wait one minute"); return }
            attempts += 1
            guard packet.body == Data(pairingCode.utf8) else { link?.close("Incorrect pairing code"); return }
            touchLock.lock(); connectedSnapshot = true; touchLock.unlock()
            authenticated = true; sequence = 0; ticks = 0
            state.frames = 0; state.message = "iPad connected — ready for games"; changed(state)
            link?.send(LinkPacket(kind: .welcome, body: LinkPacket.descriptor))
            touchLock.lock(); let menu = menuSnapshot; touchLock.unlock()
            link?.send(LinkPacket(kind: .menuState, body: menu.encoded))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
            return
        }
        switch packet.kind {
        case .menuCommand:
            let command = try LinkMenuCommand(packet.body)
            touchLock.lock()
            if menuSnapshot.active && menuCommands.count < 32 { menuCommands.append(command) }
            touchLock.unlock()
        case .analog:
            let x = Int16(bitPattern: UInt16(packet.body.readBE(0, count: 2)))
            let y = Int16(bitPattern: UInt16(packet.body.readBE(2, count: 2)))
            touchLock.lock(); analogSnapshot = (x, y); touchLock.unlock()
        case .buttons:
            let buttons = UInt16(packet.body.readBE(0, count: 2))
            guard buttons & 0xf000 == 0 else { throw LinkError.invalidPacket }
            touchLock.lock(); buttonsSnapshot = buttons; touchLock.unlock()
        case .touch: try state.touch.apply(LinkTouch(packet.body)); publishTouch()
        case .frameAck:
            guard let first = awaitingAcks.first, first.sequence == packet.sequence else { throw LinkError.invalidPacket }
            awaitingAcks.removeFirst()
            ackMS = Double(DispatchTime.now().uptimeNanoseconds - first.sentAt) / 1_000_000
        case .ping: link?.send(LinkPacket(kind: .pong, sequence: packet.sequence))
        default: throw LinkError.invalidPacket
        }
    }
    private func tick() {
        ticks += 1
        if ticks % 15 == 0 {
            changed(state)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-DSTVCompanionSmoke") {
                print("Companion timings: generate \(generationMS) ms, delivery/ACK \(ackMS) ms")
            }
            #endif
        }
        if let first = awaitingAcks.first, DispatchTime.now().uptimeNanoseconds - first.sentAt > 2_000_000_000 {
            link?.close("Frame acknowledgement timed out"); return
        }
        // Two frames cover a Wi-Fi round trip without an unbounded send queue.
        guard awaitingAcks.count < 2 else { return }
        let preparingAt = DispatchTime.now().uptimeNanoseconds
        guard let pixels = nextPixels() else { return }
        sequence &+= 1; sentAt = DispatchTime.now().uptimeNanoseconds
        awaitingAcks.append((sequence, sentAt))
        let packet = LinkPixels.packet(pixels, sequence: sequence)
        generationMS = Double(DispatchTime.now().uptimeNanoseconds - preparingAt) / 1_000_000
        link?.send(packet); state.frames &+= 1
    }
    func stop(completion: @escaping @Sendable () -> Void = {}) { queue.async { [self] in stopOnQueue(); completion() } }
    private func stopOnQueue() {
        listener?.cancel(); listener = nil; timer?.cancel(); timer = nil
        link?.close("Companion service stopped"); link = nil
        touchLock.lock(); connectedSnapshot = false; buttonsSnapshot = 0; analogSnapshot = (0, 0); menuCommands.removeAll(); touchLock.unlock()
        authenticated = false; awaitingAcks.removeAll()
        state.touch = LinkTouchState(); publishTouch()
        state.port = nil; state.message = "Companion service stopped"; changed(state)
    }
}
