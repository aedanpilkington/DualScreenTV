import Foundation
import Network

nonisolated final class BackupTestAddress: @unchecked Sendable { var value: String? }
@main struct AutomaticBackupTests {
    static func reject(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Invalid backup unexpectedly accepted") } catch { }
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BackupTests-" + UUID().uuidString)
        let suite = "DualScreenTV.BackupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = try GameLibraryDisk(root: root.appendingPathComponent("TV"), defaults: defaults)
        var rom = Data(count: 4096)
        for offset in [0x20, 0x30] { rom[offset+1] = 2; rom[offset+13] = 1 }
        let upload = library.uploadDirectory.appendingPathComponent("test.nds"); try rom.write(to: upload)
        let game = try library.importROM(upload, filename: "Backup Test.nds")
        try fm.createDirectory(at: library.savesDirectory, withIntermediateDirectories: true)
        let battery = SaveDisk(directory: library.savesDirectory, romID: game.id)
        try battery.write(Data(repeating: 42, count: 8192))
        let native = library.savesDirectory.appendingPathComponent("Dust").appendingPathComponent(game.id)
        try fm.createDirectory(at: native, withIntermediateDirectories: true)
        try Data([7,8,9]).write(to: native.appendingPathComponent("game.sav"))
        var hidden = URLResourceValues(); hidden.isHidden = true
        var hiddenSave = native.appendingPathComponent("game.sav")
        try hiddenSave.setResourceValues(hidden)
        let state = StateDisk(directory: library.root.appendingPathComponent("States"), romID: game.id, coreID: "test-core")
        try state.write(Data(repeating: 3, count: 512), slot: 1)
        let source = AutomaticBackupSource(library: library)
        let catalog = try source.catalog()
        assert(catalog.items.count == 3 && catalog.items.filter({ $0.kind != "saves" }).count == 1, "Do not mislabel DS states as other cores")
        let dust = catalog.items.first { $0.core == "Dust" }!
        let bytes = try source.download(id: dust.id, revision: dust.revision)
        let envelope = try BackupEnvelope.decode(bytes)
        assert(envelope.files.contains { $0.path == "game.sav" && $0.data == Data([7,8,9]) })
        let vault = BackupVault(root: root.appendingPathComponent("Companion"))
        try vault.store(bytes, expected: dust)
        assert(vault.contains(dust))
        for i in 0..<7 {
            let files = [BackupPayload(path: "game.sav", data: Data([UInt8(i)]))]
            let item = BackupDescriptor(id: dust.id, revision: BackupEnvelope.revision(files), sourceID: dust.sourceID, gameID: dust.gameID, title: dust.title, core: dust.core, kind: dust.kind, created: Date(timeIntervalSinceNow: Double(i+1)), bytes: 1)
            let archive = BackupEnvelope(version: 1, item: item, files: files)
            try vault.store(archive.encoded(), expected: item)
        }
        let versions = try vault.entries(); assert(versions.count == 5)
        reject { try vault.store(Data(bytes.prefix(20)), expected: dust) }
        let retained = try vault.entries(); assert(retained.count == 5, "Interrupted/corrupt downloads must not prune verified copies")
        let invalidPaths = ["../escape", "/absolute", "a//b", "a/../b", "a\\b", ".hidden", "a:stream", "a\nb"]
        for path in invalidPaths {
            let invalid = BackupEnvelope(version: 1, item: dust, files: [BackupPayload(path: path, data: Data([1]))])
            reject { _ = try invalid.encoded() }
        }
        let corrupt = BackupEnvelope(version: 1, item: dust, files: [BackupPayload(path: "game.sav", data: Data([0]))])
        reject { try corrupt.validate() }
        let revision = try source.catalog().items.first { $0.id == dust.id }!.revision
        assert(revision == dust.revision, "Unchanged saves must not create new revisions")
        try Data([0]).write(to: native.appendingPathComponent("game.sav"))
        try source.restore(bytes)
        let restoredBytes = try Data(contentsOf: native.appendingPathComponent("game.sav")); assert(restoredBytes == Data([7,8,9]))
        let linked = native.appendingPathComponent("game.sav")
        try fm.removeItem(at: linked)
        let outside = root.appendingPathComponent("outside"); try Data([99]).write(to: outside)
        try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        reject { try source.restore(bytes) }
        let outsideBytes = try Data(contentsOf: outside); assert(outsideBytes == Data([99]))
        try fm.removeItem(at: linked); try Data([7,8,9]).write(to: linked)

        let ready = DispatchSemaphore(value: 0), address = BackupTestAddress()
        var server = LocalTransferServer(library: library, coreHash: String(repeating: "a", count: 64), pairingCode: "123456", status: { _, urls in address.value = urls.last; ready.signal() }, changed: {})
        server.start()
        let started = await Task.detached { ready.wait(timeout: .now()+8) == .success }.value
        assert(started); let base = address.value!
        defer { server.stop(); server.queue.sync {} }
        let session = URLSession(configuration: .ephemeral)
        func request(_ path: String, body: Data? = nil, token: String? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: base + path)!); request.timeoutInterval = 15
            if let body { request.httpMethod = "POST"; request.httpBody = body }
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request); return (data, (response as! HTTPURLResponse).statusCode)
        }
        let denied = try await request("/automatic-backups/catalog"); assert(denied.1 == 400)
        let paired = try await request("/backup-pair", body: JSONEncoder().encode(["code":"123456", "name":"Test Mac"]))
        assert(paired.1 == 200)
        let credential = try JSONDecoder().decode(BackupPairReply.self, from: paired.0)
        let listing = try await request("/automatic-backups/catalog", token: credential.token); assert(listing.1 == 200)
        let remote = try JSONDecoder().decode(BackupCatalogResponse.self, from: listing.0)
        assert(remote.sourceID == credential.sourceID && remote.items.count == 3)
        let selection = remote.items.first { $0.core == "Dust" }!
        let download = try await request("/automatic-backups/download?id=\(selection.id)&revision=\(selection.revision)", token: credential.token)
        assert(download.1 == 200); _ = try BackupEnvelope.decode(download.0)
        let cannotWrite = try await request("/automatic-backups/automatic-restore", body: bytes, token: credential.token); assert(cannotWrite.1 == 400)
        let cannotReadOther = try await request("/\(credential.token)/games"); assert(cannotReadOther.1 == 400)
        let cannotRestore = try await request("/\(credential.token)/automatic-restore", body: bytes); assert(cannotRestore.1 == 400)
        let restored = try await request("/\(server.token)/automatic-restore", body: bytes); assert(restored.1 == 200)
        let stopped = DispatchSemaphore(value: 0); server.stop { stopped.signal() }
        _ = await Task.detached { stopped.wait(timeout: .now()+8) }.value
        server = LocalTransferServer(library: library, coreHash: String(repeating: "a", count: 64), pairingCode: "654321", status: { _, _ in ready.signal() }, changed: {})
        server.start(); _ = await Task.detached { ready.wait(timeout: .now()+8) }.value
        let remembered = try await request("/automatic-backups/catalog", token: credential.token); assert(remembered.1 == 200, "Trust must survive TV service/app relaunch")
        defaults.set(true, forKey: "backup.forgetDevices")
        let revoked = try await request("/automatic-backups/catalog", token: credential.token); assert(revoked.1 == 400)
        assert(!defaults.bool(forKey: "backup.forgetDevices"))
        defaults.set(false, forKey: "backup.enabled")
        let disabled = try await request("/backup-pair", body: JSONEncoder().encode(["code":"654321", "name":"Test Mac"]))
        assert(disabled.1 == 400)
        // Losing the TV cache must never delete the independent versions.
        server.stop(); server.queue.sync {}; try fm.removeItem(at: library.root)
        let afterPurge = try vault.entries(); assert(afterPurge.count == 5)
        print("Automatic backups: checksum/path rejection, revision deduplication, five-version retention, interrupted writes, native restore, symlink refusal, scoped auth, restart/revocation and TV cache loss passed")
    }
}
