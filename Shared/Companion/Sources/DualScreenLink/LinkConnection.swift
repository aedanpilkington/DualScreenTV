import Foundation
import Network

// The supplied serial queue owns all transport state. Reads are strictly bounded
// to one header/body. Application frame acknowledgements bound the TCP pipeline.
nonisolated final class LinkConnection: @unchecked Sendable {
    static let service = "_dstv-link._tcp"
    let connection: NWConnection
    let queue: DispatchQueue
    var received: ((LinkPacket) throws -> Void)?
    var ended: ((String) -> Void)?
    var ready: (() -> Void)?
    private var closed = false
    private var lastReceive = DispatchTime.now().uptimeNanoseconds
    private var watchdog: DispatchSourceTimer?
    init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.ready?(); self.readHeader()
            case .failed(let error): self.close(error.localizedDescription)
            case .cancelled: self.close("Disconnected")
            default: break
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if DispatchTime.now().uptimeNanoseconds - self.lastReceive > 8_000_000_000 { self.close("Connection timed out") }
        }
        watchdog = timer; timer.resume(); connection.start(queue: queue)
    }
    func send(_ packet: LinkPacket, done: (() -> Void)? = nil) {
        guard !closed else { return }
        connection.send(content: packet.encoded, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if let error { self.close(error.localizedDescription) } else { done?() }
        })
    }
    private func readHeader() {
        read(LinkPacket.headerSize) { [weak self] bytes in
            guard let self else { return }
            do {
                let (kind, count, sequence, timestamp) = try LinkPacket.header(bytes)
                if count == 0 { try self.deliver(LinkPacket(kind: kind, sequence: sequence, timestamp: timestamp)); return }
                self.read(count) { [weak self] body in
                    guard let self else { return }
                    do { try self.deliver(LinkPacket(kind: kind, sequence: sequence, timestamp: timestamp, body: body)) }
                    catch { self.close("Invalid companion packet") }
                }
            } catch { self.close("Unsupported or malformed companion protocol") }
        }
    }
    private func read(_ count: Int, completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == count else { self.close("Connection ended during a packet"); return }
            self.lastReceive = DispatchTime.now().uptimeNanoseconds
            completion(data)
            if complete { self.close("Disconnected") }
        }
    }
    private func deliver(_ packet: LinkPacket) throws { try received?(packet); readHeader() }
    func close(_ reason: String = "Disconnected") {
        guard !closed else { return }
        closed = true; watchdog?.cancel(); watchdog = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let callback = ended; ended = nil; received = nil; ready = nil
        callback?(reason)
    }
}
