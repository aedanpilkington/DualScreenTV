import Foundation
import CryptoKit

// Runs exclusively on LocalTransferServer's utility queue. That service is
// drained before a core launches, so native save files are never copied live.
nonisolated struct AutomaticBackupSource {
    let library: GameLibraryDisk
    var sourceID: String {
        if let value = library.defaults.string(forKey: "backup.sourceID"), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString; library.defaults.set(value, forKey: "backup.sourceID"); return value
    }
    private func cores(_ game: GameEntry) -> [String] { game.system == .nintendoDS ? ["melonDS", "DeSmuME", "Dust"] : [game.system.saveCore] }
    private func source(_ game: GameEntry, core: String) -> URL {
        core == "melonDS" ? library.savesDirectory : library.savesDirectory.appendingPathComponent(core).appendingPathComponent(game.id)
    }
    private func history(_ game: GameEntry, core: String) -> SaveHistory {
        SaveHistory(source: source(game, core: core), destination: library.root.appendingPathComponent("SaveHistory").appendingPathComponent(game.id).appendingPathComponent(core), filePrefix: core == "melonDS" ? game.id : nil)
    }
    private func envelope(game: GameEntry, core: String, kind: String, date: Date, files: [BackupPayload]) throws -> BackupEnvelope {
        let item = BackupDescriptor(id: BackupEnvelope.identity(sourceID: sourceID, gameID: game.id, core: core, kind: kind), revision: BackupEnvelope.revision(files), sourceID: sourceID, gameID: game.id, title: game.title, core: core, kind: kind, created: date, bytes: files.reduce(0) { $0 + $1.data.count })
        let value = BackupEnvelope(version: 1, item: item, files: files); try value.validate(); return value
    }
    func catalog() throws -> BackupCatalogResponse {
        var items: [BackupDescriptor] = []
        for game in try library.entries() {
            for core in cores(game) {
                var probe = library.root
                let relative = source(game, core: core).path.dropFirst(library.root.path.count).split(separator: "/")
                for part in relative {
                    probe.appendPathComponent(String(part))
                    if FileManager.default.fileExists(atPath: probe.path), try probe.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw BackupFailure.invalid("Linked save folders are not supported.") }
                }
                let history = history(game, core: core)
                try history.capture()
                if let latest = try history.entries().first {
                    let files = try history.backupFiles(latest)
                    if !files.isEmpty { items.append(try envelope(game: game, core: core, kind: "saves", date: latest.date, files: files).item) }
                }
                if ["DeSmuME", "Dust", "3DS"].contains(core) { continue }
                let states = library.root.appendingPathComponent("States").appendingPathComponent(["melonDS", "DeSmuME", "Dust", "3DS"].contains(core) ? "" : core)
                for slot in 1...10 {
                    let file = states.appendingPathComponent("\(game.id).slot-\(slot).dstvstate")
                    guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]), values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size <= BackupEnvelope.maximumPayload else { continue }
                    let payload = BackupPayload(path: file.lastPathComponent, data: try Data(contentsOf: file))
                    items.append(try envelope(game: game, core: core, kind: "state-\(slot)", date: values.contentModificationDate ?? Date(), files: [payload]).item)
                }
            }
        }
        return BackupCatalogResponse(sourceID: sourceID, items: items)
    }
    func download(id: String, revision: String, knownItem: BackupDescriptor? = nil) throws -> Data {
        guard BackupEnvelope.isHash(id), BackupEnvelope.isHash(revision),
              let item = try knownItem ?? catalog().items.first(where: { $0.id == id && $0.revision == revision }),
              item.id == id, item.revision == revision, item.sourceID == sourceID,
              let game = try library.entries().first(where: { $0.id == item.gameID }) else { throw BackupFailure.invalid("Save changed; retry the backup.") }
        let files: [BackupPayload]
        if item.kind == "saves" {
            let history = history(game, core: item.core)
            guard let latest = try history.entries().first else { throw BackupFailure.invalid("Save unavailable.") }
            files = try history.backupFiles(latest)
        } else {
            let directory = library.root.appendingPathComponent("States").appendingPathComponent(["melonDS", "DeSmuME", "Dust", "3DS"].contains(item.core) ? "" : item.core)
            let slot = String(item.kind.dropFirst(6))
            let path = "\(game.id).slot-\(slot).dstvstate"
            files = [BackupPayload(path: path, data: try Data(contentsOf: directory.appendingPathComponent(path)))]
        }
        guard BackupEnvelope.revision(files) == revision else { throw BackupFailure.invalid("Save changed; retry the backup.") }
        return try BackupEnvelope(version: 1, item: item, files: files).encoded()
    }
    func restore(_ data: Data) throws {
        let backup = try BackupEnvelope.decode(data)
        guard let game = try library.entries().first(where: { $0.id == backup.item.gameID }), cores(game).contains(backup.item.core) else {
            throw BackupFailure.invalid("Import this game's original ROM first. Saves belong to the exact game and core.")
        }
        let destination: URL
        if backup.item.kind == "saves" {
            destination = source(game, core: backup.item.core)
            if backup.item.core == "melonDS" {
                guard backup.files.allSatisfy({ $0.path == game.id + ".dstvsave" || $0.path == game.id + ".dstvsave.backup" }) else { throw BackupFailure.invalid("Invalid DS save filenames.") }
            }
            try history(game, core: backup.item.core).capture()
        } else {
            let slot = String(backup.item.kind.dropFirst(6))
            guard backup.files.count == 1, backup.files[0].path == "\(game.id).slot-\(slot).dstvstate" else { throw BackupFailure.invalid("Invalid state filename.") }
            destination = library.root.appendingPathComponent("States").appendingPathComponent(["melonDS", "DeSmuME", "Dust", "3DS"].contains(backup.item.core) ? "" : backup.item.core)
        }
        // Validate every destination before changing any file. Refuse symlinks
        // at roots and all intermediate components, including an existing leaf.
        for payload in backup.files {
            var probe = library.root
            let relative = destination.path.dropFirst(library.root.path.count).split(separator: "/").map(String.init) + payload.path.split(separator: "/").map(String.init)
            for part in relative {
                probe.appendPathComponent(part)
                if FileManager.default.fileExists(atPath: probe.path), try probe.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw BackupFailure.invalid("Linked save paths are not supported.") }
            }
        }
        // Retain current files in a recovery checkpoint before a manual restore.
        let recovery = SaveHistory(source: destination, destination: library.root.appendingPathComponent("RestoreRecovery").appendingPathComponent(game.id).appendingPathComponent(backup.item.core), filePrefix: backup.item.core == "melonDS" || backup.item.kind != "saves" ? game.id : nil)
        try recovery.capture()
        var previous: [String: Data] = [:], previousBytes = 0
        for payload in backup.files {
            let file = destination.appendingPathComponent(payload.path)
            if FileManager.default.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= BackupEnvelope.maximumPayload - previousBytes else { throw BackupFailure.invalid("Cannot safely preserve current saves for rollback.") }
                previous[payload.path] = try Data(contentsOf: file); previousBytes += size
            }
        }
        var written: [String] = []
        do {
            for payload in backup.files {
                let file = destination.appendingPathComponent(payload.path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try payload.data.write(to: file, options: .atomic); written.append(payload.path)
            }
        } catch {
            for path in written.reversed() {
                let file = destination.appendingPathComponent(path)
                if let old = previous[path] { try old.write(to: file, options: .atomic) }
                else { try FileManager.default.removeItem(at: file) }
            }
            throw error
        }
    }
}
