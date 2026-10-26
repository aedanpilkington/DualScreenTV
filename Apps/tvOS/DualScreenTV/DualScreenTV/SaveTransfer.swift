import Foundation
import CryptoKit

// Portable validated checkpoints, not arbitrary archive paths. Browser routes
// carry only a library game ID and slot; every disk path is constructed here.
nonisolated struct SaveTransfer {
    let library: GameLibraryDisk
    let coreHash: String
    func game(_ id: String) throws -> GameEntry {
        guard GameIdentity.valid(id), let game = try library.entries().first(where: { $0.id == id }) else { throw LibraryError.invalid("Unknown game.") }
        guard game.system == .nintendoDS else { throw LibraryError.invalid("3DS saves use the core’s virtual SD card. Browser checkpoint backups are currently available for DS games only.") }
        return game
    }
    func location(id: String, slot: Int) throws -> URL {
        _ = try game(id)
        if slot == 0 { return SaveDisk(directory: library.savesDirectory, romID: id).url }
        return try StateDisk(directory: library.statesDirectory, romID: id, coreID: coreHash).url(slot: slot)
    }
    func validated(_ url: URL, id: String, slot: Int, requireCompatibleCore: Bool = true) throws -> Data {
        let game = try game(id)
        let limit = slot == 0 ? SaveDisk.maximumSRAM : StateDisk.maximumSize
        let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard count > 0, count <= limit + 4096 else { throw LibraryError.invalid("Invalid checkpoint size.") }
        let data = try Data(contentsOf: url)
        guard let archive = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              archive["version"] as? Int == 1, archive["romID"] as? String == id,
              let payload = archive["payload"] as? Data, !payload.isEmpty, payload.count <= limit,
              archive["checksum"] as? Data == Data(SHA256.hash(data: payload)) else {
            throw LibraryError.invalid("Invalid checkpoint or different game. No save was changed.")
        }
        if slot == 0 {
            if let size = game.sramSize, size > 0, payload.count != size { throw LibraryError.invalid("Save size does not match this game.") }
        } else {
            guard (1...10).contains(slot), archive["slot"] as? Int == slot,
                  let archivedCore = archive["coreID"] as? String, GameIdentity.valid(archivedCore),
                  !requireCompatibleCore || archivedCore == coreHash else { throw LibraryError.invalid("State belongs to another slot or emulator build.") }
            if requireCompatibleCore, let size = game.stateSize, size > 0, payload.count != size { throw LibraryError.invalid("State size does not match this game.") }
        }
        return data
    }
    func restore(_ temporary: URL, id: String, slot: Int) throws {
        let destination = try location(id: id, slot: slot)
        let bytes = try validated(temporary, id: id, slot: slot)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Retain only a checked prior generation, never rotate corrupt content.
        if let previous = try? validated(destination, id: id, slot: slot) {
            try previous.write(to: destination.appendingPathExtension("backup"), options: .atomic)
        }
        try bytes.write(to: destination, options: .atomic)
    }
    func export(id: String, slot: Int) throws -> URL {
        let source = try location(id: id, slot: slot)
        // Match runtime fallback policy and export the last validated checkpoint.
        for candidate in [source, source.appendingPathExtension("backup")] {
            if (try? validated(candidate, id: id, slot: slot, requireCompatibleCore: false)) != nil { return candidate }
        }
        throw LibraryError.invalid("No valid checkpoint is stored for this game/slot yet.")
    }
}

// The explorer exposes only one selected game's save tree, never arbitrary
// filesystem paths. Imports require a previously created file/template.
nonisolated struct SaveFileEntry: Codable {
    let name: String
    let path: String
    let directory: Bool
    let size: Int
    let modified: Date?
    let portable: Bool
}
nonisolated struct SaveExplorer {
    let backups: SaveTransfer
    static let maximumFile = 64 * 1024 * 1024
    private func game(_ id: String, core: String) throws -> GameEntry {
        guard GameIdentity.valid(id), let game = try backups.library.entries().first(where: { $0.id == id }),
              (game.system == .nintendoDS ? ["melonDS", "Dust", "DeSmuME"] : [game.system.saveCore]).contains(core) else {
            throw LibraryError.invalid("Choose a matching game and save core.")
        }
        return game
    }
    private func checked(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.utf8.count <= 2048, parts.count <= 20,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(":") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw LibraryError.invalid("Invalid save path.")
        }
        return parts
    }
    private func nativeURL(id: String, core: String, path: String) throws -> URL {
        _ = try game(id, core: core)
        guard core != "melonDS" else { throw LibraryError.invalid("Choose an in-game save.") }
        let root = backups.library.savesDirectory.appendingPathComponent(core).appendingPathComponent(id)
        var url = root
        for part in try checked(path) { url.appendPathComponent(part) }
        // Check every component, including core roots, so a symlink cannot escape.
        var probe = backups.library.savesDirectory
        for part in [core, id] + (try checked(path)) {
            probe.appendPathComponent(part)
            if FileManager.default.fileExists(atPath: probe.path) {
                guard try probe.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw LibraryError.invalid("Linked save paths are not supported.")
                }
            }
        }
        return url
    }
    func list(id: String, core: String, path: String) throws -> [SaveFileEntry] {
        _ = try game(id, core: core)
        if core == "melonDS" || core == "mGBA" {
            guard path.isEmpty else { throw LibraryError.invalid("Invalid save folder.") }
            guard let source = try? batteryURL(id, core: core), FileManager.default.fileExists(atPath: source.path) else { return [] }
            let data = try portableBattery(id, core: core)
            return [SaveFileEntry(name: "In-game save.sav", path: "save.sav", directory: false, size: data.count,
                modified: try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, portable: true)]
        }
        let folder = try nativeURL(id: id, core: core, path: path)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles)
        return try files.compactMap { file in
            let v = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            let name = file.lastPathComponent
            guard v.isSymbolicLink != true, v.isDirectory == true || v.isRegularFile == true,
                  !name.hasSuffix(".before-import"), !name.hasSuffix(".tmp"), !name.hasPrefix("pipelines-") else { return nil }
            return SaveFileEntry(name: name, path: path.isEmpty ? name : path + "/" + name,
                directory: v.isDirectory == true, size: v.fileSize ?? 0, modified: v.contentModificationDate,
                portable: core != "3DS" && ["sav", "dsv"].contains(file.pathExtension.lowercased()))
        }.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func batteryDirectory(_ id: String, core: String) -> URL {
        core == "mGBA" ? backups.library.savesDirectory.appendingPathComponent("mGBA").appendingPathComponent(id) : backups.library.savesDirectory
    }
    private func batteryURL(_ id: String, core: String) throws -> URL {
        if core == "melonDS" { return try backups.export(id: id, slot: 0) }
        let url = SaveDisk(directory: batteryDirectory(id, core: core), romID: id).url
        return FileManager.default.fileExists(atPath: url.path) ? url : url.appendingPathExtension("backup")
    }
    private func portableBattery(_ id: String, core: String) throws -> Data {
        let disk = SaveDisk(directory: batteryDirectory(id, core: core), romID: id)
        for source in [disk.url, disk.url.appendingPathExtension("backup")] {
            guard let bytes = try? read(source),
                  let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let payload = plist["payload"] as? Data,
                  let loaded = try? disk.load(expectedSize: payload.count) else { continue }
            return loaded.data
        }
        throw LibraryError.invalid("No valid battery save is stored for this game.")
    }
    private func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= Self.maximumFile else {
            throw LibraryError.invalid("Choose a save file no larger than 64 MB.")
        }
        return try Data(contentsOf: url)
    }
    // DeSmuME footer v0: five LE u32 fields, version, 16-byte cookie.
    static func dsvPayload(_ data: Data) throws -> Data {
        let text = Data("|<--Snip above here to create a raw sav by excluding this DeSmuME savedata footer:".utf8)
        let cookie = Data("|-DESMUME SAVE-|".utf8)
        guard data.count > text.count + 40, data.suffix(16) == cookie else { throw LibraryError.invalid("Invalid DeSmuME save footer.") }
        let offset = data.count - 40
        func word(_ n: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[offset + n + $1]) << (8 * $1) } }
        let padded = word(4)
        guard word(20) == 0, padded > 0, padded + text.count == offset,
              data[padded..<offset] == text else { throw LibraryError.invalid("Unsupported DeSmuME save layout.") }
        return Data(data.prefix(padded))
    }
    func export(id: String, core: String, path: String, raw: Bool) throws -> (Data, String) {
        let game = try game(id, core: core)
        let data: Data
        var name: String
        if core == "melonDS" || core == "mGBA" {
            guard path == "save.sav" else { throw LibraryError.invalid("Unknown save file.") }
            data = try portableBattery(id, core: core); name = "save.sav"
        } else {
            let url = try nativeURL(id: id, core: core, path: path)
            let bytes = try read(url)
            data = raw && core == "DeSmuME" && url.pathExtension.lowercased() == "dsv" ? try Self.dsvPayload(bytes) : bytes
            name = raw && url.pathExtension.lowercased() == "dsv" ? url.deletingPathExtension().lastPathComponent + ".sav" : url.lastPathComponent
        }
        if core != "3DS" && core != "PSP" { name = game.title + "." + (name as NSString).pathExtension }
        // ASCII attachment name; the UI still displays the full game title.
        name = String(name.unicodeScalars.map { (CharacterSet.alphanumerics.contains($0) && $0.isASCII) || " ._-".unicodeScalars.contains($0) ? Character(String($0)) : "_" }.prefix(160))
        return (data, name)
    }
    func restore(_ temporary: URL, id: String, core: String, path: String) throws {
        _ = try game(id, core: core)
        let incoming = try read(temporary)
        if core == "melonDS" || core == "mGBA" {
            guard path == "save.sav" else { throw LibraryError.invalid("Unknown save file.") }
            let old = try portableBattery(id, core: core)
            guard incoming.count == old.count else { throw LibraryError.invalid("Save size does not match. Export a raw .sav from your Mac emulator.") }
            let disk = SaveDisk(directory: batteryDirectory(id, core: core), romID: id)
            _ = try disk.load(expectedSize: old.count)
            try disk.write(incoming)
        } else {
            let destination = try nativeURL(id: id, core: core, path: path)
            let old = try read(destination)
            var replacement = incoming
            if core == "DeSmuME" && destination.pathExtension.lowercased() == "dsv" {
                let template = try Self.dsvPayload(old)
                let payload = incoming.suffix(16) == Data("|-DESMUME SAVE-|".utf8) ? try Self.dsvPayload(incoming) : incoming
                guard payload.count == template.count else { throw LibraryError.invalid("Save size does not match this game’s DeSmuME save.") }
                replacement = payload + old.suffix(old.count - template.count)
            } else if core != "3DS" && core != "PSP" {
                guard incoming.count == old.count else { throw LibraryError.invalid("Save size does not match this game.") }
            }
            try old.write(to: destination.appendingPathExtension("before-import"), options: .atomic)
            try replacement.write(to: destination, options: .atomic)
        }
    }
}
