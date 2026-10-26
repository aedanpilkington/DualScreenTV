import Foundation
import Network
import CryptoKit
import Darwin

// One intentionally scoped service, three bounded connections, one HTTP request
// per connection. All file IO runs on this utility queue, never the frame owner.
nonisolated final class LocalTransferServer: @unchecked Sendable {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let pairingCode: String
    private var pairingAttempts = 0
    private var pairingWindow = ProcessInfo.processInfo.systemUptime
    let queue = DispatchQueue(label: "DualScreenTV.LocalTransfer", qos: .utility)
    let library: GameLibraryDisk
    let backups: SaveTransfer
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var running = false
    private var backupItems: [String: BackupDescriptor] = [:]
    private var uploadReceipts: [String: String] = [:]
    let status: @Sendable (String, [String]) -> Void
    let changed: @Sendable () -> Void
    let activity: @Sendable (Bool) -> Void
    init(library: GameLibraryDisk, coreHash: String, pairingCode: String = String(format: "%06u", UInt32.random(in: 0...999_999)), activity: @escaping @Sendable (Bool) -> Void = { _ in }, status: @escaping @Sendable (String, [String]) -> Void,
         changed: @escaping @Sendable () -> Void) {
        if library.defaults.bool(forKey: "backup.forgetDevices") {
            library.defaults.removeObject(forKey: "backup.trusted"); library.defaults.set(false, forKey: "backup.forgetDevices")
        }
        self.activity = activity
        self.pairingCode = pairingCode
        self.library = library; backups = SaveTransfer(library: library, coreHash: coreHash)
        self.status = status; self.changed = changed
    }
    func start() {
        queue.async { [self] in
            guard !running else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.includePeerToPeer = false
                parameters.allowLocalEndpointReuse = true
                // A stable port makes the displayed .local address bookmarkable.
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 8765)!)
                self.listener = listener; running = true
                listener.service = NWListener.Service(name: "DualScreenTV", type: "_http._tcp")
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener?.port else { return }
                        let urls = Self.addresses().map { "http://\($0):\(port.rawValue)" }
                        self.status(urls.isEmpty ? "Connect Apple TV to Wi-Fi or Ethernet, then reopen Add Games." : "Ready for games and save backups", urls)
                    case .failed(let error): self.status("Transfer service failed: \(error.localizedDescription)", []); self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.running, self.clients.count < 3 else { connection.cancel(); return }
                    let client = Client(connection: connection, server: self)
                    self.clients[client.id] = client; self.activity(true); client.start()
                }
                listener.start(queue: queue)
            } catch { status("Cannot start transfer: \(error.localizedDescription)", []) }
        }
    }
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in stopOnQueue(); completion() }
    }
    // Queue-owned rate limit is checked before comparing codes, so a guessed
    // correct code cannot bypass the five-attempt-per-minute budget.
    private func pair(_ code: String) throws -> String {
        let now = ProcessInfo.processInfo.systemUptime
        if now - pairingWindow >= 60 { pairingWindow = now; pairingAttempts = 0 }
        guard pairingAttempts < 5 else { throw LibraryError.invalid("Too many code attempts. Wait one minute and try again.") }
        pairingAttempts += 1
        guard code == pairingCode else { throw LibraryError.invalid("Incorrect code. Enter the six digits shown on Apple TV.") }
        return "/" + token
    }
    private func stopOnQueue() {
        running = false; listener?.cancel(); listener = nil
        let active = Array(clients.values); clients.removeAll(); activity(false)
        for client in active { client.close() }
    }
    static func addresses() -> [String] {
        var result: [String] = []
        var name = [CChar](repeating: 0, count: 256)
        if gethostname(&name, name.count) == 0 {
            let host = String(cString: name)
            if !host.isEmpty && host != "localhost" { result.append(host.hasSuffix(".local") ? host : host + ".local") }
        }
        var pointer: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&pointer) == 0 {
            defer { freeifaddrs(pointer) }
            var current = pointer
            while let address = current {
                defer { current = address.pointee.ifa_next }
                let item = address.pointee
                guard let socket = item.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                      item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                      String(cString: item.ifa_name).hasPrefix("en") else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(socket, socklen_t(socket.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.append(String(cString: buffer))
                }
            }
        }
        return Array(NSOrderedSet(array: result)) as? [String] ?? result
    }

    private final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        unowned let server: LocalTransferServer
        var header = Data()
        var request: TransferRequest?
        var route: (path: String, query: [String: String])?
        var received = 0
        var uploadHash = SHA256()
        var pairingBody = Data()
        var temporary: URL?
        var file: FileHandle?
        var download: FileHandle?
        var closed = false
        var responding = false
        var timeout: DispatchWorkItem?
        let started = Date()
        init(connection: NWConnection, server: LocalTransferServer) { self.connection = connection; self.server = server }
        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state { self.close() }
                if case .cancelled = state { self.close() }
            }
            connection.start(queue: server.queue)
            receive()
        }
        func armTimeout() {
            timeout?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.close() }
            timeout = work; server.queue.asyncAfter(deadline: .now() + 120, execute: work)
        }
        func receive() {
            guard !closed, !responding else { return }
            guard Date().timeIntervalSince(started) < 2 * 60 * 60 else { close(); return }
            armTimeout()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { return }
                do {
                    if let data, !data.isEmpty { try self.consume(data) }
                    if self.responding { return }
                    if error != nil || complete { self.fail("Incomplete upload. No file was imported."); return }
                    self.receive()
                } catch { self.fail(error.localizedDescription) }
            }
        }
        func consume(_ data: Data) throws {
            if request == nil {
                header.append(data)
                guard let end = header.range(of: Data("\r\n\r\n".utf8)) else {
                    guard header.count <= TransferRequest.maximumHeader else { throw LibraryError.invalid("HTTP header too large.") }
                    return
                }
                let parsed = try TransferRequest.parse(Data(header[..<end.lowerBound]))
                let body = Data(header[end.upperBound...]); header.removeAll(keepingCapacity: false)
                let savedSession = parsed.target.dropFirst()
                let expiredBookmark = parsed.target.hasPrefix("/") && savedSession.count == 64
                    && savedSession.allSatisfy { $0.isASCII && $0.isHexDigit }
                    && parsed.target != "/" + server.token
                if parsed.method == "GET" && (parsed.target == "/" || expiredBookmark) {
                    guard parsed.length == 0, body.isEmpty else { throw LibraryError.invalid("Unexpected request body.") }
                    respond(Data(TransferPage.pairingHTML.utf8), type: "text/html; charset=utf-8"); return
                }
                let pairing = parsed.method == "POST" && ["/pair", "/backup-pair"].contains(parsed.target)
                let backupRead = parsed.method == "GET" && parsed.target.hasPrefix("/automatic-backups/")
                let route: (path: String, query: [String: String])
                if pairing { route = (parsed.target, [:]) }
                else if backupRead {
                    let defaults = server.library.defaults
                    if defaults.bool(forKey: "backup.forgetDevices") { defaults.removeObject(forKey: "backup.trusted"); defaults.set(false, forKey: "backup.forgetDevices") }
                    let bearer = parsed.headers["authorization"] ?? ""
                    guard defaults.object(forKey: "backup.enabled") == nil || defaults.bool(forKey: "backup.enabled"), bearer.hasPrefix("Bearer "),
                          BackupEnvelope.isHash(String(bearer.dropFirst(7))),
                          defaults.dictionary(forKey: "backup.trusted")?[BackupEnvelope.hash(Data(bearer.dropFirst(7).utf8))] != nil else { throw LibraryError.invalid("Backup device is not paired. Enter the TV code again.") }
                    route = try parsed.route(token: "automatic-backups")
                    guard ["/catalog", "/download"].contains(route.path) else { throw LibraryError.invalid("Unknown backup endpoint.") }
                } else { route = try parsed.route(token: server.token) }
                self.request = parsed; self.route = route
                if pairing {
                    guard parsed.length <= (route.path == "/backup-pair" ? 256 : 32) else { throw LibraryError.invalid("Enter the six-digit code only.") }
                    try bodyChunk(body); return
                }
                if parsed.method == "GET" {
                    guard parsed.length == 0, body.isEmpty else { throw LibraryError.invalid("Unexpected request body.") }
                    try get(route); return
                }
                guard ["/rom", "/restore", "/artwork", "/remove-artwork", "/rename", "/save-import", "/automatic-restore"].contains(route.path) else { throw LibraryError.invalid("Unknown upload endpoint.") }
                if route.path == "/automatic-restore" {
                    guard parsed.length <= BackupEnvelope.maximumEncoded else { throw LibraryError.invalid("Backup is too large.") }
                } else if route.path == "/rom" {
                    let name = try ROMValidation.filename(route.query["name"] ?? "")
                    _ = try ROMValidation.system(for: name)
                    if let id = route.query["upload"] {
                        guard !id.isEmpty, id.count <= 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else { throw LibraryError.invalid("Invalid upload identifier.") }
                    }
                } else if route.path == "/save-import" {
                    _ = try SaveExplorer(backups: server.backups).list(id: route.query["id"] ?? "", core: route.query["core"] ?? "", path: "")
                    guard parsed.length <= SaveExplorer.maximumFile else { throw LibraryError.invalid("Save files must be no larger than 64 MB.") }
                } else if route.path == "/rename" {
                    guard let id = route.query["id"], GameIdentity.valid(id),
                          try server.library.entries().contains(where: { $0.id == id }) else { throw LibraryError.invalid("Unknown game.") }
                    guard parsed.length > 0, parsed.length <= 1024 else { throw LibraryError.invalid("Enter a shorter game name.") }
                } else if route.path == "/artwork" || route.path == "/remove-artwork" {
                    guard let id = route.query["id"], GameIdentity.valid(id),
                          try server.library.entries().contains(where: { $0.id == id }) else { throw LibraryError.invalid("Unknown game.") }
                    let limit = route.path == "/artwork" ? GameArtwork.maximumUpload : 16
                    guard parsed.length > 0, parsed.length <= limit else { throw LibraryError.invalid("Artwork must be no larger than 8 MB.") }
                } else {
                    let (id, slot) = try selection(route.query)
                    _ = try server.backups.location(id: id, slot: slot)
                    let limit = slot == 0 ? SaveDisk.maximumSRAM : StateDisk.maximumSize
                    guard parsed.length <= limit + 4096 else { throw LibraryError.invalid("Checkpoint is too large.") }
                }
                let url = server.library.uploadDirectory.appendingPathComponent(UUID().uuidString + ".upload")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw LibraryError.invalid("Apple TV has insufficient writable storage.") }
                temporary = url; file = try FileHandle(forWritingTo: url)
                try bodyChunk(body)
            } else { try bodyChunk(data) }
        }
        func selection(_ query: [String: String]) throws -> (String, Int) {
            guard let id = query["id"], GameIdentity.valid(id), let raw = query["slot"], let slot = Int(raw), (0...10).contains(slot) else { throw LibraryError.invalid("Invalid game or checkpoint slot.") }
            return (id, slot)
        }
        func bodyChunk(_ bytes: Data) throws {
            guard let request, let route, !responding, bytes.count <= request.length - received else { throw LibraryError.invalid("Unexpected upload length.") }
            received += bytes.count
            if ["/pair", "/backup-pair"].contains(route.path) {
                pairingBody.append(bytes)
                if received == request.length {
                    if route.path == "/backup-pair" {
                        struct Pair: Decodable { let code: String; let name: String }
                        let body = try JSONDecoder().decode(Pair.self, from: pairingBody)
                        _ = try server.pair(body.code)
                        let defaults = server.library.defaults
                        guard defaults.object(forKey: "backup.enabled") == nil || defaults.bool(forKey: "backup.enabled") else { throw LibraryError.invalid("Automatic backups are disabled in TV Settings.") }
                        var trusted = defaults.dictionary(forKey: "backup.trusted") as? [String: String] ?? [:]
                        guard trusted.count < 8 else { throw LibraryError.invalid("Eight backup devices are already paired. Forget old devices in TV Settings.") }
                        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                        trusted[BackupEnvelope.hash(Data(token.utf8))] = String(body.name.prefix(80))
                        defaults.set(trusted, forKey: "backup.trusted")
                        respond(try JSONEncoder().encode(BackupPairReply(sourceID: AutomaticBackupSource(library: server.library).sourceID, token: token)), type: "application/json")
                    } else {
                        let code = String(data: pairingBody, encoding: .utf8) ?? ""
                        respond(Data(try server.pair(code).utf8))
                    }
                }
                return
            }
            try file?.write(contentsOf: bytes)
            if route.path == "/rom" { uploadHash.update(data: bytes) }
            guard received == request.length, let temporary else { return }
            try file?.synchronize(); try file?.close(); file = nil
            if route.path == "/automatic-restore" {
                try AutomaticBackupSource(library: server.library).restore(Data(contentsOf: temporary))
                respond(Data("Backup restored. Reopen the game to continue.".utf8))
            } else if route.path == "/rom" {
                let identity = uploadHash.finalize().map { String(format: "%02x", $0) }.joined()
                let game = try server.library.importROM(temporary, filename: route.query["name"] ?? "", streamedIdentity: identity)
                let message = "Imported \(game.title)"
                if let id = route.query["upload"] {
                    if server.uploadReceipts.count >= 256 { server.uploadReceipts.removeAll() }
                    server.uploadReceipts[id] = message
                }
                server.changed(); respond(Data(message.utf8))
            } else if route.path == "/save-import" {
                try SaveExplorer(backups: server.backups).restore(temporary, id: route.query["id"] ?? "", core: route.query["core"] ?? "", path: route.query["path"] ?? "")
                respond(Data("Save imported. Reopen the game on Apple TV to continue.".utf8))
            } else if route.path == "/rename" {
                guard let id = route.query["id"], let name = String(data: try Data(contentsOf: temporary), encoding: .utf8) else {
                    throw LibraryError.invalid("Invalid game name.")
                }
                try server.library.rename(id, to: name)
                server.changed(); respond(Data("Name saved. Choose Done on Apple TV to see your library.".utf8))
            } else if route.path == "/artwork" || route.path == "/remove-artwork" {
                guard let id = route.query["id"] else { throw LibraryError.invalid("Missing game ID.") }
                if route.path == "/artwork" { try server.library.setArtwork(temporary, id: id) }
                else { try server.library.removeArtwork(id) }
                server.changed(); respond(Data("Artwork updated. Choose Done on Apple TV to see your library.".utf8))
            } else {
                let (id, slot) = try selection(route.query)
                try server.backups.restore(temporary, id: id, slot: slot)
                respond(Data("Checkpoint restored. Launch the game to use it.".utf8))
            }
        }
        func get(_ route: (path: String, query: [String: String])) throws {
            switch route.path {
            case "", "/": respond(Data(TransferPage.html.utf8), type: "text/html; charset=utf-8")
            case "/catalog":
                let catalog = try AutomaticBackupSource(library: server.library).catalog()
                server.backupItems = Dictionary(uniqueKeysWithValues: catalog.items.map { ($0.id, $0) })
                respond(try JSONEncoder().encode(catalog), type: "application/json")
            case "/download":
                respond(try AutomaticBackupSource(library: server.library).download(id: route.query["id"] ?? "", revision: route.query["revision"] ?? "", knownItem: server.backupItems[route.query["id"] ?? ""]), type: "application/octet-stream")
            case "/info":
                let defaults = server.library.defaults
                let core = defaults.bool(forKey: "graphics.ds.dustGPUCore") ? "Dust" : (defaults.bool(forKey: "graphics.ds.highResolutionCore") ? "DeSmuME" : "melonDS")
                respond(try JSONEncoder().encode(["dsSaveCore": core, "storage": "purgeable"]), type: "application/json")
            case "/upload-status":
                let message = server.uploadReceipts[route.query["id"] ?? ""]
                struct Receipt: Encodable { let complete: Bool; let message: String }
                respond(try JSONEncoder().encode(Receipt(complete: message != nil, message: message ?? "")), type: "application/json")
            case "/diagnostics":
                let url = server.library.root.appendingPathComponent("last-game-report.txt")
                let data = (try? Data(contentsOf: url)) ?? Data("Play a game, then return to the library to create a report.".utf8)
                respond(data, type: "text/plain; charset=utf-8", extra: "Content-Disposition: attachment; filename=\"DualScreenTV-game-report.txt\"\r\n")
            case "/games": respond(try JSONEncoder().encode(server.library.entries()), type: "application/json")
            case "/save-files":
                respond(try JSONEncoder().encode(SaveExplorer(backups: server.backups).list(id: route.query["id"] ?? "", core: route.query["core"] ?? "", path: route.query["path"] ?? "")), type: "application/json")
            case "/save-export":
                let (bytes, name) = try SaveExplorer(backups: server.backups).export(id: route.query["id"] ?? "", core: route.query["core"] ?? "", path: route.query["path"] ?? "", raw: route.query["format"] != "native")
                respond(bytes, type: "application/octet-stream", extra: "Content-Disposition: attachment; filename=\"\(name)\"\r\n")
            case "/picture":
                guard let id = route.query["id"], GameIdentity.valid(id), let game = try server.library.entries().first(where: { $0.id == id }),
                      let url = server.library.artworkURL(game.artwork) else { throw LibraryError.invalid("No picture for this game.") }
                respond(try Data(contentsOf: url), type: "image/jpeg")
            case "/save":
                let (id, slot) = try selection(route.query)
                let source = try server.backups.export(id: id, slot: slot)
                let length = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                download = try FileHandle(forReadingFrom: source)
                responding = true
                let filename = id + (slot == 0 ? ".dstvsave" : ".slot-\(slot).dstvstate")
                send(Data(responseHeader(length: length, type: "application/octet-stream", extra: "Content-Disposition: attachment; filename=\"\(filename)\"\r\n").utf8)) { [weak self] in self?.sendDownloadChunk() }
            default: throw LibraryError.invalid("Unknown endpoint.")
            }
        }
        func responseHeader(length: Int, type: String, code: Int = 200, extra: String = "") -> String {
            "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Bad Request")\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'\r\n\(extra)\r\n"
        }
        func respond(_ body: Data, type: String = "text/plain; charset=utf-8", code: Int = 200, extra: String = "") {
            guard !closed, !responding else { return }
            responding = true
            var response = Data(responseHeader(length: body.count, type: type, code: code, extra: extra).utf8); response.append(body)
            send(response) { [weak self] in self?.close() }
        }
        func send(_ data: Data, done: @escaping @Sendable () -> Void) {
            armTimeout()
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.close() } else { done() }
            })
        }
        func sendDownloadChunk() {
            do {
                guard let bytes = try download?.read(upToCount: 64 * 1024), !bytes.isEmpty else { close(); return }
                send(bytes) { [weak self] in self?.sendDownloadChunk() }
            } catch { close() }
        }
        func fail(_ message: String) { respond(Data(message.utf8), code: 400) }
        func close() {
            guard !closed else { return }
            closed = true; timeout?.cancel(); connection.cancel()
            try? file?.close(); try? download?.close(); file = nil; download = nil
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            server.clients.removeValue(forKey: id)
            server.activity(!server.clients.isEmpty)
        }
    }
}
