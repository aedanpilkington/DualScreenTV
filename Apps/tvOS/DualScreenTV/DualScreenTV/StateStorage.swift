import CryptoKit
import Foundation

// No core pointers here. Access instances only on StateManager's serial I/O
// queue. ROM and exact core binary identity prevent incompatible state loads.
nonisolated struct StateDisk {
    static let maximumSize = 128 * 1024 * 1024
    let directory: URL
    let romID: String
    let coreID: String
    private struct Archive: Codable {
        let version: Int
        let romID: String
        let coreID: String
        let slot: Int
        let payload: Data
        let checksum: Data
    }
    func url(slot: Int) throws -> URL {
        guard (1...10).contains(slot) else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appendingPathComponent("\(romID).slot-\(slot).dstvstate")
    }
    private func read(_ url: URL, slot: Int, size: Int) throws -> Data {
        guard size > 0, size <= Self.maximumSize else { throw CocoaError(.fileReadCorruptFile) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let count = attributes[.size] as? NSNumber,
              count.intValue <= Self.maximumSize + 4096 else { throw CocoaError(.fileReadCorruptFile) }
        let archive = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1, archive.romID == romID, archive.coreID == coreID,
              archive.slot == slot, archive.payload.count == size,
              archive.checksum == Data(SHA256.hash(data: archive.payload)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive.payload
    }
    func load(slot: Int, size: Int) throws -> (payload: Data, backup: Bool) {
        let primary = try url(slot: slot)
        do { return (try read(primary, slot: slot, size: size), false) }
        catch {
            return (try read(primary.appendingPathExtension("backup"), slot: slot, size: size), true)
        }
    }
    func write(_ payload: Data, slot: Int) throws {
        guard !payload.isEmpty, payload.count <= Self.maximumSize else { throw CocoaError(.fileWriteInvalidFileName) }
        let primary = try url(slot: slot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Rotate only a validated prior generation. Preserve a good backup if
        // the primary is corrupt, incompatible, or missing.
        if (try? read(primary, slot: slot, size: payload.count)) != nil {
            try Data(contentsOf: primary).write(to: primary.appendingPathExtension("backup"), options: .atomic)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let archive = Archive(version: 1, romID: romID, coreID: coreID, slot: slot,
                              payload: payload, checksum: Data(SHA256.hash(data: payload)))
        try encoder.encode(archive).write(to: primary, options: .atomic)
    }
}


nonisolated struct StateSlotInfo: Identifiable {
    let slot: Int
    let date: Date?
    let thumbnail: Data?
    var id: Int { slot }
}
nonisolated extension StateDisk {
    func slots() -> [StateSlotInfo] {
        (1...10).map { slot in
            let file = try? url(slot: slot)
            let date = file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            let image = file.flatMap { try? Data(contentsOf: $0.appendingPathExtension("png")) }
            return StateSlotInfo(slot: slot, date: date, thumbnail: image)
        }
    }
    func thumbnail(_ data: Data?, slot: Int) throws {
        let path = try url(slot: slot).appendingPathExtension("png")
        if let data { try data.write(to: path, options: .atomic) }
        else { try? FileManager.default.removeItem(at: path) }
    }
}
