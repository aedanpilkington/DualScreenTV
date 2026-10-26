import Foundation

@main
struct GameLibraryTests {
    static func rejects(_ work: () throws -> Void) { do { try work(); fatalError("Expected rejection") } catch {} }
    static func check(_ value: Bool) { assert(value) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "DualScreenTV.LibraryTests." + UUID().uuidString)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removeObject(forKey: GameLibraryDisk.metadataKey) }
        let library = try GameLibraryDisk(root: root, defaults: defaults)
        func fixture(_ name: String) throws -> URL {
            let url = library.uploadDirectory.appendingPathComponent(name)
            var data = Data(count: 4096)
            for offset in [0x20, 0x30] { data[offset + 1] = 2; data[offset + 13] = 1 }
            try data.write(to: url); return url
        }
        check(try ROMValidation.system(for: "Cart.gba") == .gameBoyAdvance)
        check(try ROMValidation.system(for: "Cart.GBC") == .gameBoyColor)
        check(try ROMValidation.system(for: "Game.iso") == .psp)
        assert(GameSystem.gameBoy.coreIdentifier == GameSystem.gameBoyAdvance.coreIdentifier)
        let gbURL = library.uploadDirectory.appendingPathComponent("gb-fixture")
        var gb = Data(count: 32768); gb[0x104] = 0xce; gb[0x105] = 0xed
        try gb.write(to: gbURL)
        check(try ROMValidation.detectedSystem(gbURL, filename: "Cart.gb") == .gameBoy)
        gb[0x143] = 0x80; try gb.write(to: gbURL)
        check(try ROMValidation.detectedSystem(gbURL, filename: "Cart.gb") == .gameBoyColor)
        let original = try library.importROM(fixture("a"), filename: "Game.nds")
        assert(GameIdentity.valid(original.id))
        assert(original.saveNamespace == original.id && original.stateNamespace == original.id)
        try library.update(original.id) { $0.favourite = true; $0.lastPlayed = Date(); $0.sramSize = 32; $0.stateSize = 64 }
        let renamed = try library.importROM(fixture("b"), filename: "Renamed.NDS")
        assert(renamed.id == original.id && renamed.favourite)
        check(try library.entries().count == 1)
        let secondReader = try GameLibraryDisk(root: root, defaults: defaults)
        check(try secondReader.entries().first?.id == original.id)
        try library.rename(original.id, to: "  Pokémon Mystery Dungeon  ")
        let retitled = try library.entries()[0]
        assert(retitled.title == "Pokémon Mystery Dungeon" && retitled.filename == "Renamed.NDS")
        assert(retitled.id == original.id && retitled.saveNamespace == original.saveNamespace)
        for invalidName in ["", "   ", "Line\nBreak", String(repeating: "a", count: 241), String(repeating: "🎮", count: 61)] {
            rejects { try library.rename(original.id, to: invalidName) }
        }
        rejects { try library.rename(String(repeating: "f", count: 64), to: "Unknown") }
        let importedAgain = try library.importROM(fixture("renamed-again"), filename: "Long Filename.nds")
        assert(importedAgain.title == retitled.title)
        let persisted = try secondReader.entries()[0]
        assert(persisted.title == retitled.title && ShelfGame.snapshot([persisted])[0].title == retitled.title)
        let core = String(repeating: "a", count: 64)
        let transfer = SaveTransfer(library: library, coreHash: core)
        try FileManager.default.createDirectory(at: library.savesDirectory, withIntermediateDirectories: true)
        let save = SaveDisk(directory: library.savesDirectory, romID: original.id)
        try save.write(Data(repeating: 7, count: 32))
        let export = try transfer.export(id: original.id, slot: 0)
        let copied = root.appendingPathComponent("copy"); try FileManager.default.copyItem(at: export, to: copied)
        try transfer.restore(copied, id: original.id, slot: 0)
        assert(FileManager.default.fileExists(atPath: export.appendingPathExtension("backup").path))
        let state = StateDisk(directory: library.statesDirectory, romID: original.id, coreID: core)
        try state.write(Data(repeating: 9, count: 64), slot: 2)
        let stateURL = try transfer.export(id: original.id, slot: 2)
        try transfer.restore(stateURL, id: original.id, slot: 2)
        rejects { try transfer.restore(stateURL, id: original.id, slot: 1) }
        let otherBuild = SaveTransfer(library: library, coreHash: String(repeating: "b", count: 64))
        let historicalExport = try otherBuild.export(id: original.id, slot: 2)
        assert(historicalExport == stateURL) // Back up old states even if this build cannot restore them.
        rejects { try otherBuild.restore(stateURL, id: original.id, slot: 2) }
        let corrupt = root.appendingPathComponent("bad"); try Data("garbage".utf8).write(to: corrupt)
        let before = try Data(contentsOf: export)
        rejects { try transfer.restore(corrupt, id: original.id, slot: 0) }
        check(try Data(contentsOf: export) == before)
        let wrongSize = SaveDisk(directory: root, romID: original.id); try wrongSize.write(Data([1]))
        rejects { try transfer.restore(wrongSize.url, id: original.id, slot: 0) }
        let wrongGame = SaveDisk(directory: root, romID: String(repeating: "f", count: 64)); try wrongGame.write(Data(repeating: 7, count: 32))
        rejects { try transfer.restore(wrongGame.url, id: original.id, slot: 0) }
        let picture = root.appendingPathComponent("picture")
        let romBefore = try Data(contentsOf: library.romURL(original.id))
        for type in ["public.png", "public.jpeg"] {
            try artworkFixture(type: type, width: 1400, height: 700).write(to: picture)
            try library.setArtwork(picture, id: original.id)
            let entry = try library.entries()[0]
            let artURL = library.artworkURL(entry.artwork)!
            assert(GameArtwork.validFilename(entry.artwork!))
            assert(GameArtwork.load(artURL, maximum: 1024)!.width == 1024)
            assert(GameArtwork.load(artURL, maximum: 1024)!.height == 576)
            assert(artworkHasBlueCorner(GameArtwork.load(artURL)!)) // Filled, without padding.
            assert(ShelfGame.snapshot([entry])[0].artwork == entry.artwork)
        }
        // Existing version-1 uploads have padding baked into their PNGs.
        try artworkFixture(width: 1024, height: 576, padded: true).write(to: picture)
        let oldName = try SaveDisk.identity(for: picture) + ".png"
        try Data(contentsOf: picture).write(to: library.artworkURL(oldName)!)
        try library.update(original.id) { $0.artwork = oldName; $0.artworkVersion = nil }
        let upgradedReader = try GameLibraryDisk(root: root, defaults: defaults)
        let upgraded = try upgradedReader.entries()[0]
        assert(upgraded.artworkVersion == 2 && upgraded.artwork != oldName)
        assert(artworkHasBlueCorner(GameArtwork.load(upgradedReader.artworkURL(upgraded.artwork)!)!))
        assert(!FileManager.default.fileExists(atPath: library.artworkURL(oldName)!.path))
        let existingArt = try library.entries()[0].artwork
        try Data("not a picture".utf8).write(to: picture)
        rejects { try library.setArtwork(picture, id: original.id) }
        check(try library.entries()[0].artwork == existingArt)
        try artworkFixture(width: 8193, height: 1).write(to: picture)
        rejects { try library.setArtwork(picture, id: original.id) }
        try Data(count: GameArtwork.maximumUpload + 1).write(to: picture)
        rejects { try library.setArtwork(picture, id: original.id) }
        try artworkFixture().write(to: picture)
        rejects { try library.setArtwork(picture, id: String(repeating: "e", count: 64)) }
        assert(library.artworkURL("../escape.png") == nil)
        assert(library.artworkURL("/tmp/escape.png") == nil)
        check(try Data(contentsOf: library.romURL(original.id)) == romBefore)
        check(try Data(contentsOf: export) == before)
        try library.removeArtwork(original.id)
        check(try library.entries()[0].artwork == nil)
        check(try FileManager.default.contentsOfDirectory(atPath: library.artworkDirectory.path).isEmpty)
        try library.removeArtwork(original.id) // Idempotent, including reclaimed files.
        try library.removeROM(original.id)
        check(try library.entries().first?.availability == .needsImport)
        assert(FileManager.default.fileExists(atPath: export.path))
        check(ShelfGame.snapshot(try library.entries()).isEmpty)
        let restored = try library.importROM(fixture("c"), filename: "Another.nds")
        assert(restored.id == original.id && restored.favourite)
        let shelf = ShelfGame.snapshot(try library.entries())
        assert(shelf.count == 1 && shelf[0].id == original.id)
        for filename in ["../bad.nds", "a/b.nds", "a\\b.nds", "a\n.nds", "", "x:y.nds"] { rejects { _ = try ROMValidation.filename(filename) } }
        rejects { _ = try library.importROM(fixture("zip"), filename: "Game.zip") }
        try Data(count: 512).write(to: corrupt)
        rejects { try ROMValidation.validate(corrupt, filename: "fake.nds") }
        assert(GameIdentity.deepLink(GameIdentity.link(original.id)) == original.id)
        for link in ["dualscreentv://game/../bad", "dualscreentv://game/" + original.id + "?path=foo", "http://game/" + original.id, "dualscreentv://evil/" + original.id] { assert(GameIdentity.deepLink(URL(string: link)!) == nil) }
        let request = try TransferRequest.parse(Data("POST /secret/rom?name=Game.nds HTTP/1.1\r\nHost: local:80\r\nOrigin: http://local:80\r\nContent-Length: 4096".utf8))
        assert(request.length == 4096 && request.method == "POST")
        check(try request.route(token: "secret").query["name"] == "Game.nds")
        rejects { _ = try request.route(token: "expired") }
        for header in ["POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1", "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4294967297", "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2", "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked", "GET / HTTP/1.1\r\nHost: a\r\nOrigin: http://evil"] { rejects { _ = try TransferRequest.parse(Data(header.utf8)) } }
        var cxi = Data(count: 4096)
        cxi.replaceSubrange(0x100..<0x104, with: Data("NCCH".utf8))
        cxi[0x104] = 8; cxi[0x18f] = 4
        let threeUpload = root.appendingPathComponent("three")
        try cxi.write(to: threeUpload)
        let three = try library.importROM(threeUpload, filename: "Example.cxi")
        assert(three.system == .nintendo3DS && three.core == .azahar)
        check(try library.romURL(three.id).pathExtension == "cxi")
        rejects { _ = try transfer.export(id: three.id, slot: 0) }
        try cxi.write(to: threeUpload)
        let threeAgain = try library.importROM(threeUpload, filename: "Same.3ds")
        assert(threeAgain.id == three.id)
        check(try library.romURL(three.id).pathExtension == "cxi")
        try library.removeROM(three.id)
        check(try library.entries().first(where: { $0.id == three.id })?.availability == .needsImport)
        cxi[0x18f] = 0; try cxi.write(to: threeUpload)
        rejects { try ROMValidation.validate(threeUpload, filename: "Encrypted.cxi") }
        cxi[0x18f] = 4; cxi[0x104] = 9; try cxi.write(to: threeUpload)
        rejects { try ROMValidation.validate(threeUpload, filename: "Truncated.cxi") }
        var gba = Data(count: 1024); gba[0xb2] = 0x96
        let gbaUpload = root.appendingPathComponent("gba"); try gba.write(to: gbaUpload)
        let advance = try library.importROM(gbaUpload, filename: "Homebrew.gba")
        assert(advance.system == .gameBoyAdvance && advance.core == .mgba)
        let gbaSaves = library.savesDirectory.appendingPathComponent("mGBA").appendingPathComponent(advance.id)
        try FileManager.default.createDirectory(at: gbaSaves, withIntermediateDirectories: true)
        let gbaDisk = SaveDisk(directory: gbaSaves, romID: advance.id)
        try gbaDisk.write(Data(repeating: 3, count: 128))
        let explorer = SaveExplorer(backups: transfer)
        check(try explorer.list(id: advance.id, core: "mGBA", path: "").first?.size == 128)
        check(try explorer.export(id: advance.id, core: "mGBA", path: "save.sav", raw: true).0 == Data(repeating: 3, count: 128))
        try gbaDisk.write(Data(repeating: 4, count: 128))
        try Data([0]).write(to: SaveDisk(directory: gbaSaves, romID: advance.id).url)
        check(try explorer.export(id: advance.id, core: "mGBA", path: "save.sav", raw: true).0 == Data(repeating: 3, count: 128))
        rejects { _ = try explorer.list(id: advance.id, core: "PSP", path: "") }
        var pbp = Data(count: 512); pbp.replaceSubrange(0..<4, with: Data([0, 0x50, 0x42, 0x50]))
        let pspUpload = root.appendingPathComponent("psp"); try pbp.write(to: pspUpload)
        let portable = try library.importROM(pspUpload, filename: "Homebrew.pbp")
        assert(portable.system == .psp && portable.core == .ppsspp)
        let pspSaves = library.savesDirectory.appendingPathComponent("PSP").appendingPathComponent(portable.id).appendingPathComponent("PSP/SAVEDATA/TEST")
        try FileManager.default.createDirectory(at: pspSaves, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: pspSaves.appendingPathComponent("DATA.BIN"))
        check(try explorer.list(id: portable.id, core: "PSP", path: "PSP/SAVEDATA/TEST").first?.name == "DATA.BIN")
        rejects { _ = try explorer.list(id: portable.id, core: "PSP", path: "../mGBA") }
        try library.deleteGame(portable.id)
        check(try !library.entries().contains { $0.id == portable.id })
        check(try !FileManager.default.fileExists(atPath: library.romURL(portable.id).path))
        check(FileManager.default.fileExists(atPath: pspSaves.appendingPathComponent("DATA.BIN").path))
        try pbp.write(to: pspUpload)
        let restoredPortable = try library.importROM(pspUpload, filename: "Homebrew.pbp")
        assert(restoredPortable.id == portable.id)
        try library.removeROM(portable.id)
        try library.deleteGame(portable.id)
        check(try !library.entries().contains { $0.id == portable.id })
        print("Game library/transfer: persistence, identity, rename, missing ROM, save preservation, safe restore, namespaces, links, shelf and HTTP validation passed")
    }
}
