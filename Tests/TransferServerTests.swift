import Foundation
import Network

nonisolated final class TransferAddress: @unchecked Sendable { var urls: [String] = [] }
@main
struct TransferServerTests {
    static func waitReady(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success) }
        }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "DualScreenTV.ServerTests." + UUID().uuidString)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removeObject(forKey: GameLibraryDisk.metadataKey) }
        let library = try GameLibraryDisk(root: root, defaults: defaults)
        let ready = DispatchSemaphore(value: 0), address = TransferAddress()
        let server = LocalTransferServer(library: library, coreHash: String(repeating: "a", count: 64), pairingCode: "123456", status: { _, urls in address.urls = urls; ready.signal() }, changed: {})
        server.start()
        guard await waitReady(ready), let shortAddress = address.urls.last, let base = URL(string: shortAddress) else { fatalError("Listener failed") }
        defer { server.stop(); server.queue.sync {} }
        assert(base.port == 8765)
        let raw = shortAddress + "/" + server.token
        assert(server.pairingCode == "123456")
        assert(server.pairingCode.count == 6 && server.pairingCode.allSatisfy(\.isNumber))
        let session = URLSession(configuration: .ephemeral)
        let (pairingPage, _) = try await session.data(from: URL(string: shortAddress)!)
        assert(String(data: pairingPage, encoding: .utf8)!.contains("Connection code"))
        let expired = shortAddress + "/" + String(repeating: "0", count: 64)
        let (expiredPage, expiredResponse) = try await session.data(from: URL(string: expired)!)
        assert((expiredResponse as! HTTPURLResponse).statusCode == 200)
        assert(String(data: expiredPage, encoding: .utf8)!.contains("Connection code"))
        func pair(_ code: String) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: shortAddress + "/pair")!)
            request.httpMethod = "POST"; request.httpBody = Data(code.utf8)
            let (data, response) = try await session.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        let paired = try await pair(server.pairingCode)
        assert(paired.1 == 200 && String(data: paired.0, encoding: .utf8) == "/" + server.token)
        let badCode = server.pairingCode == "000000" ? "111111" : "000000"
        for _ in 0..<4 { let rejected = try await pair(badCode); assert(rejected.1 == 400) }
        let limited = try await pair(server.pairingCode)
        assert(limited.1 == 400 && String(data: limited.0, encoding: .utf8)!.contains("Too many"))
        func request(_ path: String, body: Data? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: raw + path)!)
            request.timeoutInterval = 5
            if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: request)
            return (data, (response as! HTTPURLResponse).statusCode)
        }
        try Data("Test game report".utf8).write(to: root.appendingPathComponent("last-game-report.txt"))
        let report = try await request("/diagnostics")
        assert(report.1 == 200 && String(data: report.0, encoding: .utf8) == "Test game report")
        let page = try await request("")
        assert(page.1 == 200 && String(data: page.0, encoding: .utf8)!.contains("Save backups"))
        var rom = Data(count: 4096)
        for offset in [0x20, 0x30] { rom[offset + 1] = 2; rom[offset + 13] = 1 }
        let upload = try await request("/rom?name=Test.nds&upload=receipt1", body: rom)
        assert(upload.1 == 200)
        let receipt = try await request("/upload-status?id=receipt1")
        let receiptJSON = try JSONSerialization.jsonObject(with: receipt.0) as! [String: Any]
        assert(receipt.1 == 200 && receiptJSON["complete"] as? Bool == true && receiptJSON["message"] as? String == "Imported Test")
        let pendingReceipt = try await request("/upload-status?id=unknown")
        let pendingJSON = try JSONSerialization.jsonObject(with: pendingReceipt.0) as! [String: Any]
        assert(pendingJSON["complete"] as? Bool == false)

        let listing = try await request("/games")
        let games = try JSONDecoder().decode([GameEntry].self, from: listing.0)
        assert(games.count == 1)
        let diskIdentity = try SaveDisk.identity(for: library.romURL(games[0].id))
        assert(games[0].id == diskIdentity, "Streaming and file hashing must produce identical save identities")
        let renamed = try await request("/rename?id=" + games[0].id, body: Data("  Pokémon Mystery Dungeon  ".utf8))
        assert(renamed.1 == 200)
        let renameListing = try await request("/games")
        let renamedGames = try JSONDecoder().decode([GameEntry].self, from: renameListing.0)
        assert(renamedGames[0].title == "Pokémon Mystery Dungeon" && renamedGames[0].filename == games[0].filename)
        for body in [Data("  ".utf8), Data("Line\nBreak".utf8), Data(repeating: 65, count: 1025), Data([0xff])] {
            let rejected = try await request("/rename?id=" + games[0].id, body: body)
            assert(rejected.1 == 400)
        }
        let badRename = try await request("/rename?id=..%2Fescape", body: Data("Name".utf8))
        assert(badRename.1 == 400)
        let art = try await request("/artwork?id=" + games[0].id, body: artworkFixture())
        assert(art.1 == 200)
        let withArt = try await request("/games")
        let pictured = try JSONDecoder().decode([GameEntry].self, from: withArt.0)
        assert(pictured[0].artwork != nil && library.artworkURL(pictured[0].artwork) != nil)
        let malformedArt = try await request("/artwork?id=" + games[0].id, body: Data([1, 2, 3]))
        assert(malformedArt.1 == 400)
        let unknownArt = try await request("/artwork?id=" + String(repeating: "f", count: 64), body: artworkFixture())
        assert(unknownArt.1 == 400)
        let traversalArt = try await request("/artwork?id=..%2Fescape", body: artworkFixture())
        assert(traversalArt.1 == 400)
        let removedArt = try await request("/remove-artwork?id=" + games[0].id, body: Data("remove".utf8))
        assert(removedArt.1 == 200)
        let afterArt = try library.entries()
        assert(afterArt[0].artwork == nil)
        let invalid = try await request("/rom?name=..%2Fbad.nds", body: rom)
        assert(invalid.1 == 400)
        let unsupported = try await request("/rom?name=bad.zip", body: rom)
        assert(unsupported.1 == 400)
        let incompleteROM = try await request("/rom?name=bad.nds", body: Data(repeating: 0, count: 512))
        assert(incompleteROM.1 == 400)
        try FileManager.default.createDirectory(at: library.savesDirectory, withIntermediateDirectories: true)
        let disk = SaveDisk(directory: library.savesDirectory, romID: games[0].id)
        try disk.write(Data(repeating: 8, count: 32))
        let checkpoint = try await request("/save?id=" + games[0].id + "&slot=0")
        assert(checkpoint.1 == 200)
        let restore = try await request("/restore?id=" + games[0].id + "&slot=0", body: checkpoint.0)
        assert(restore.1 == 200)
        let badRestore = try await request("/restore?id=" + games[0].id + "&slot=0", body: Data([1,2,3]))
        assert(badRestore.1 == 400)
        let before = try Data(contentsOf: disk.url)
        assert(before == checkpoint.0)
        // Older native-core sessions wrote zero into melonDS checkpoint sizes.
        try library.update(games[0].id) { $0.sramSize = 0; $0.stateSize = 0 }
        let rawSave = try await request("/save-export?id=" + games[0].id + "&core=melonDS&path=save.sav")
        assert(rawSave.1 == 200 && rawSave.0 == Data(repeating: 8, count: 32))
        let rawImport = try await request("/save-import?id=" + games[0].id + "&core=melonDS&path=save.sav", body: Data(repeating: 9, count: 32))
        assert(rawImport.1 == 200)
        let changedRaw = try await request("/save-export?id=" + games[0].id + "&core=melonDS&path=save.sav")
        assert(changedRaw.0 == Data(repeating: 9, count: 32))
        let wrongRaw = try await request("/save-import?id=" + games[0].id + "&core=melonDS&path=save.sav", body: Data([1]))
        assert(wrongRaw.1 == 400)
        let native = library.savesDirectory.appendingPathComponent("Dust").appendingPathComponent(games[0].id)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 512).write(to: native.appendingPathComponent("cartridge.sav"))
        let nativeListing = try await request("/save-files?id=" + games[0].id + "&core=Dust")
        let nativeFiles = try JSONDecoder().decode([SaveFileEntry].self, from: nativeListing.0)
        assert(nativeListing.1 == 200 && nativeFiles.count == 1 && nativeFiles[0].size == 512)
        let nativeImport = try await request("/save-import?id=" + games[0].id + "&core=Dust&path=cartridge.sav", body: Data(repeating: 6, count: 512))
        assert(nativeImport.1 == 200)
        let previousNative = try Data(contentsOf: native.appendingPathComponent("cartridge.sav.before-import"))
        assert(previousNative == Data(repeating: 7, count: 512))
        for path in ["..%2Fescape", "%2Fetc%2Fpasswd", "cartridge.sav%2F..%2Fescape"] {
            let rejected = try await request("/save-export?id=" + games[0].id + "&core=Dust&path=" + path)
            assert(rejected.1 == 400)
        }
        try FileManager.default.createSymbolicLink(at: native.appendingPathComponent("linked.sav"), withDestinationURL: disk.url)
        let linked = try await request("/save-export?id=" + games[0].id + "&core=Dust&path=linked.sav")
        assert(linked.1 == 400)
        let dsvRoot = library.savesDirectory.appendingPathComponent("DeSmuME").appendingPathComponent(games[0].id)
        try FileManager.default.createDirectory(at: dsvRoot, withIntermediateDirectories: true)
        var dsv = Data(repeating: 5, count: 512)
        dsv.append(Data("|<--Snip above here to create a raw sav by excluding this DeSmuME savedata footer:".utf8))
        for word: UInt32 in [512,512,1,2,512,0] { var le=word.littleEndian; withUnsafeBytes(of: &le) { dsv.append(contentsOf: $0) } }
        dsv.append(Data("|-DESMUME SAVE-|".utf8))
        try dsv.write(to: dsvRoot.appendingPathComponent("game.dsv"))
        let rawDsv = try await request("/save-export?id=" + games[0].id + "&core=DeSmuME&path=game.dsv")
        assert(rawDsv.1 == 200 && rawDsv.0 == Data(repeating: 5, count: 512))
        let importedDsv = try await request("/save-import?id=" + games[0].id + "&core=DeSmuME&path=game.dsv", body: Data(repeating: 3, count: 512))
        assert(importedDsv.1 == 200)
        let dsvAfter = try Data(contentsOf: dsvRoot.appendingPathComponent("game.dsv"))
        assert(dsvAfter.count == dsv.count && dsvAfter.prefix(512) == Data(repeating: 3, count: 512) && dsvAfter.suffix(dsv.count-512) == dsv.suffix(dsv.count-512))
        var threeDS = Data(count: 1024)
        threeDS.replaceSubrange(0x100..<0x104, with: Data("NCCH".utf8)); threeDS[0x104] = 2; threeDS[0x18f] = 4
        let imported3DS = try await request("/rom?name=SaveBrowser.cxi", body: threeDS)
        assert(imported3DS.1 == 200)
        let threeDSGame = try library.entries().first(where: { $0.system == .nintendo3DS })!
        let threeDSFolder = library.savesDirectory.appendingPathComponent("3DS").appendingPathComponent(threeDSGame.id).appendingPathComponent("sdmc/title/data")
        try FileManager.default.createDirectory(at: threeDSFolder, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: threeDSFolder.appendingPathComponent("main"))
        let threeDSList = try await request("/save-files?id=" + threeDSGame.id + "&core=3DS&path=sdmc%2Ftitle%2Fdata")
        let threeDSFiles = try JSONDecoder().decode([SaveFileEntry].self, from: threeDSList.0)
        assert(threeDSFiles.count == 1 && threeDSFiles[0].name == "main")
        let threeDSExport = try await request("/save-export?id=" + threeDSGame.id + "&core=3DS&path=sdmc%2Ftitle%2Fdata%2Fmain")
        assert(threeDSExport.1 == 200 && threeDSExport.0 == Data([1,2,3]))
        let threeDSRestore = try await request("/save-import?id=" + threeDSGame.id + "&core=3DS&path=sdmc%2Ftitle%2Fdata%2Fmain", body: Data([4,5,6,7]))
        assert(threeDSRestore.1 == 200)
        let wrongCore = try await request("/save-files?id=" + threeDSGame.id + "&core=Dust")
        assert(wrongCore.1 == 400)
        let wrongToken = URL(string: "http://" + base.host! + ":" + String(base.port!) + "/wrong/games")!
        let (_, response) = try await session.data(from: wrongToken)
        assert((response as! HTTPURLResponse).statusCode == 400)
        // Disconnect midway through a declared upload. It must never become a ROM.
        let connection = NWConnection(host: NWEndpoint.Host(base.host!), port: NWEndpoint.Port(rawValue: UInt16(base.port!))!, using: .tcp)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    var packet = Data("POST \(URL(string: raw)!.path)/rom?name=Interrupted.nds HTTP/1.1\r\nHost: \(base.host!):\(base.port!)\r\nContent-Length: 4096\r\n\r\n".utf8)
                    packet.append(Data(count: 100))
                    connection.send(content: packet, completion: .contentProcessed { _ in
                        connection.cancel(); continuation.resume()
                    })
                }
            }
            connection.start(queue: DispatchQueue(label: "TransferTest.Partial"))
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let remainingGames = try library.entries()
        assert(remainingGames.count == 2)
        // Completion/error paths must clean staged files.
        let pending = try FileManager.default.contentsOfDirectory(atPath: library.uploadDirectory.path)
        assert(pending.isEmpty)
        server.stop(); server.queue.sync {}
        do { _ = try await request("/games"); fatalError("Listener remained active") } catch {}
        print("Local transfer server: live HTTP page, streamed ROM import, rejection, listing, checkpoint download/restore, token and shutdown passed")
    }
}
