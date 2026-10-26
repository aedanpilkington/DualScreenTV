import Foundation
import CryptoKit

nonisolated enum BackupFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
nonisolated struct BackupDescriptor: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let revision: String
    let sourceID: String
    let gameID: String
    let title: String
    let core: String
    let kind: String // saves or state-1 ... state-10
    let created: Date
    let bytes: Int
}
nonisolated struct BackupCatalogResponse: Codable, Sendable { let sourceID: String; let items: [BackupDescriptor] }
nonisolated struct BackupPairReply: Codable, Sendable { let sourceID: String; let token: String }
nonisolated struct BackupPayload: Codable, Sendable { let path: String; let data: Data }
nonisolated struct BackupEnvelope: Codable, Sendable {
    static let maximumPayload = 128 * 1024 * 1024
    static let maximumEncoded = maximumPayload + 2 * 1024 * 1024
    let version: Int
    let item: BackupDescriptor
    let files: [BackupPayload]
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 1024 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(":") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }
    static func identity(sourceID: String, gameID: String, core: String, kind: String) -> String {
        hash(Data([sourceID, gameID, core, kind].joined(separator: "\n").utf8))
    }
    static func revision(_ files: [BackupPayload]) -> String {
        hash(Data(files.sorted { $0.path < $1.path }.map { $0.path + "\u{0}" + hash($0.data) }.joined(separator: "\n").utf8))
    }
    func validate() throws {
        guard version == 1, UUID(uuidString: item.sourceID) != nil, Self.isHash(item.gameID),
              ["melonDS", "DeSmuME", "Dust", "3DS", "mGBA", "PSP"].contains(item.core),
              item.kind == "saves" || (1...10).contains(where: { item.kind == "state-\($0)" }),
              item.title.utf8.count <= 2048, !files.isEmpty, files.count <= 4096,
              item.id == Self.identity(sourceID: item.sourceID, gameID: item.gameID, core: item.core, kind: item.kind),
              Self.isHash(item.revision), item.bytes >= 0, item.bytes <= Self.maximumPayload else { throw BackupFailure.invalid("Invalid backup metadata.") }
        var total = 0, paths = Set<String>()
        for file in files {
            guard Self.safePath(file.path), paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  file.data.count <= Self.maximumPayload - total else { throw BackupFailure.invalid("Invalid or oversized backup file.") }
            total += file.data.count
        }
        guard total == item.bytes, Self.revision(files) == item.revision else { throw BackupFailure.invalid("Backup checksum verification failed.") }
    }
    func encoded() throws -> Data {
        try validate(); let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncoded else { throw BackupFailure.invalid("Backup is too large.") }; return data
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumEncoded else { throw BackupFailure.invalid("Backup is too large.") }
        let value = try PropertyListDecoder().decode(Self.self, from: bytes); try value.validate(); return value
    }
}

// Durable on iPad/Mac, deliberately separate from Caches and temporary exports.
// Never mirror deletions from the TV. A successful atomic write precedes pruning.
nonisolated struct BackupVault {
    struct Entry: Identifiable, Sendable { let url: URL; let item: BackupDescriptor; var id: String { url.path } }
    let root: URL
    func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let groups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [Entry] = []
        for group in groups where BackupEnvelope.isHash(group.lastPathComponent) {
            let values = try group.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: group, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) where file.pathExtension == "dstvbackup" {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= BackupEnvelope.maximumEncoded else { continue }
                let index = file.appendingPathExtension("json")
                let descriptor: BackupDescriptor
                if let bytes = try? Data(contentsOf: index), let cached = try? JSONDecoder().decode(BackupDescriptor.self, from: bytes) { descriptor = cached }
                else if let bytes = try? Data(contentsOf: file), let envelope = try? BackupEnvelope.decode(bytes) {
                    descriptor = envelope.item
                    try? JSONEncoder().encode(descriptor).write(to: index, options: .atomic)
                } else { continue }
                guard descriptor.id == group.lastPathComponent, file.deletingPathExtension().lastPathComponent == descriptor.revision else { continue }
                result.append(Entry(url: file, item: descriptor))
            }
        }
        return result.sorted { $0.item.created > $1.item.created }
    }
    func contains(_ item: BackupDescriptor) -> Bool {
        let file = root.appendingPathComponent(item.id).appendingPathComponent(item.revision + ".dstvbackup")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= BackupEnvelope.maximumEncoded,
              let bytes = try? Data(contentsOf: file), let stored = try? BackupEnvelope.decode(bytes) else { return false }
        return stored.item.id == item.id && stored.item.revision == item.revision
    }
    func store(_ bytes: Data, expected: BackupDescriptor) throws {
        let envelope = try BackupEnvelope.decode(bytes)
        guard envelope.item == expected else { throw BackupFailure.invalid("Apple TV returned a different backup. Nothing replaced.") }
        let directory = root.appendingPathComponent(expected.id)
        if FileManager.default.fileExists(atPath: directory.path), try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw BackupFailure.invalid("Linked backup folders are not supported.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(expected.revision + ".dstvbackup")
        try bytes.write(to: destination, options: .atomic)
        // Verify the independent copy before reporting success or removing history.
        guard try BackupEnvelope.decode(Data(contentsOf: destination)).item == expected else { throw BackupFailure.invalid("Could not verify the saved backup.") }
        try JSONEncoder().encode(expected).write(to: destination.appendingPathExtension("json"), options: .atomic)
        for old in try entries().filter({ $0.item.id == expected.id }).dropFirst(5) {
            try FileManager.default.removeItem(at: old.url); try? FileManager.default.removeItem(at: old.url.appendingPathExtension("json"))
        }
    }
}
