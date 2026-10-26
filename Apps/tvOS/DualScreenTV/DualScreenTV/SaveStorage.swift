import CryptoKit
import Foundation

struct StorageDirectories {
    let system: URL
    let saves: URL
    let usesTemporaryFallback: Bool

    static func prepare() throws -> StorageDirectories {
        let fm = FileManager.default
        // tvOS doesn't offer iOS-style durable Documents/Application Support.
        // Probe Caches on this device and keep the proven temporary fallback.
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        for base in [cache, fm.temporaryDirectory].compactMap({ $0 }) {
            let root = base.appendingPathComponent("DualScreenTV", isDirectory: true)
            do {
                let system = root.appendingPathComponent("melonDSSystem", isDirectory: true)
                let saves = root.appendingPathComponent("Saves", isDirectory: true)
                for directory in [system, saves] {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    let probe = directory.appendingPathComponent(".write-probe-\(UUID().uuidString)")
                    try Data([0]).write(to: probe, options: .atomic)
                    try fm.removeItem(at: probe)
                }
                let fallback = base == fm.temporaryDirectory
                print("Storage: \(root.path) (\(fallback ? "temporary fallback" : "purgeable cache"))")
                return StorageDirectories(system: system, saves: saves, usesTemporaryFallback: fallback)
            } catch {
                print("Storage unavailable at \(root.path): \(error)")
            }
        }
        throw CocoaError(.fileWriteNoPermission)
    }
}

// Only accessed on SaveManager's serial I/O queue, or during startup before
// that queue is used. No live core pointers escape the main thread.
final class SaveDisk: @unchecked Sendable {
    private nonisolated struct Archive: Codable {
        let version: Int
        let romID: String
        let payload: Data
        let checksum: Data
    }
    nonisolated let url: URL
    nonisolated let romID: String
    nonisolated(unsafe) private var previousArchive: Data?
    nonisolated static let maximumSRAM = 16 * 1024 * 1024

    nonisolated init(directory: URL, romID: String) {
        self.romID = romID
        url = directory.appendingPathComponent(romID + ".dstvsave")
    }

    nonisolated static func identity(for rom: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: rom)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func decode(_ bytes: Data, expectedSize: Int) throws -> Data {
        let archive = try PropertyListDecoder().decode(Archive.self, from: bytes)
        guard archive.version == 1, archive.romID == romID,
              archive.payload.count == expectedSize,
              archive.checksum == Data(SHA256.hash(data: archive.payload)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return archive.payload
    }

    nonisolated func load(expectedSize: Int) throws -> (data: Data, recoveredBackup: Bool)? {
        var foundFile = false
        for (index, candidate) in [url, url.appendingPathExtension("backup")].enumerated() {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
                foundFile = true
                guard let size = attributes[.size] as? NSNumber,
                      size.intValue <= Self.maximumSRAM + 4096 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let bytes = try Data(contentsOf: candidate)
                let payload = try decode(bytes, expectedSize: expectedSize)
                previousArchive = bytes
                return (payload, index == 1)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                foundFile = true
                print("Save validation failed at \(candidate.path): \(error)")
            }
        }
        if foundFile { throw CocoaError(.fileReadCorruptFile) }
        return nil
    }

    nonisolated func write(_ payload: Data) throws {
        guard !payload.isEmpty, payload.count <= Self.maximumSRAM else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let archive = Archive(version: 1, romID: romID, payload: payload,
                              checksum: Data(SHA256.hash(data: payload)))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(archive)
        // Keep the previous validated generation. Never rotate an unchecked
        // or corrupt on-disk primary over the known-good backup.
        if let previousArchive {
            try previousArchive.write(to: url.appendingPathExtension("backup"), options: .atomic)
        }
        try bytes.write(to: url, options: .atomic)
        previousArchive = bytes
        // Preserve dated validated battery checkpoints as they change.
        let history = SaveHistory(source: url.deletingLastPathComponent(),
            destination: url.deletingLastPathComponent().appendingPathComponent("BatteryHistory").appendingPathComponent(romID), filePrefix: romID + ".dstvsave")
        do { try history.capture() } catch { print("Battery history: \(error)") }
    }
}

// A bounded local recovery history. Off-device export is still required to
// survive tvOS reclaiming the app's cache. Never snapshot live core file writes.
nonisolated struct SaveHistory {
    struct Entry: Identifiable { let url: URL; let date: Date; var id: String { url.lastPathComponent } }
    private struct Manifest: Codable { let files: [String: String]; let created: Date }
    private static let lock = NSRecursiveLock()
    private static let io = DispatchQueue(label: "DualScreenTV.SaveHistory", qos: .utility)
    func enqueueCapture(completion: @escaping @Sendable () -> Void = {}) {
        Self.io.async { do { try capture() } catch { print("Save history: \(error)") }; completion() }
    }
    let source: URL
    let destination: URL
    var filePrefix: String? = nil
    func entries() throws -> [Entry] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: destination.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { url in
                guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.plist")),
                      let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data) else { return nil }
                return Entry(url: url, date: manifest.created)
            }.sorted { $0.date > $1.date }
    }
    private func files() throws -> [String: Data] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return [:] }
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [:] }
        var result: [String: Data] = [:]; var total = 0
        for case let url as URL in enumerator {
            let rootPath = source.resolvingSymlinksInPath().path + "/"
            let fullPath = url.resolvingSymlinksInPath().path
            guard fullPath.hasPrefix(rootPath) else { enumerator.skipDescendants(); continue }
            let path = String(fullPath.dropFirst(rootPath.count))
            // Finder hidden flags may be attached to valid native save files.
            // Ignore dot paths explicitly rather than losing those saves.
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { enumerator.skipDescendants(); continue }
            let lower = path.lowercased()
            if lower.contains("history") || lower.contains("shader") || lower.contains("cache") || lower.contains("texture") { enumerator.skipDescendants(); continue }
            if let filePrefix, !path.hasPrefix(filePrefix) { enumerator.skipDescendants(); continue }
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attrs.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
            guard attrs.isRegularFile == true else { continue }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            total += size
            guard total <= 128 * 1024 * 1024, result.count < 4096 else { throw CocoaError(.fileWriteOutOfSpace) }
            result[path] = try Data(contentsOf: url)
        }
        return result
    }
    func capture() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fm = FileManager.default
        let payloads = try files()
        guard !payloads.isEmpty else { return }
        let hashes = payloads.mapValues { Data(SHA256.hash(data: $0)).base64EncodedString() }
        let existing = try entries()
        if let newest = existing.first,
           let old = try? PropertyListDecoder().decode(Manifest.self, from: Data(contentsOf: newest.url.appendingPathComponent("manifest.plist"))), old.files == hashes { return }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let temporary = destination.appendingPathComponent("." + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        for (path, data) in payloads {
            let url = temporary.appendingPathComponent("files").appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(Manifest(files: hashes, created: Date())).write(to: temporary.appendingPathComponent("manifest.plist"), options: .atomic)
        try fm.moveItem(at: temporary, to: destination.appendingPathComponent(UUID().uuidString))
        for old in try entries().dropFirst(5) { try fm.removeItem(at: old.url) }
    }
    func backupFiles(_ entry: Entry) throws -> [BackupPayload] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try entries().contains(where: { $0.url == entry.url }) else { throw CocoaError(.fileReadInvalidFileName) }
        let manifest = try PropertyListDecoder().decode(Manifest.self, from: Data(contentsOf: entry.url.appendingPathComponent("manifest.plist")))
        var result: [BackupPayload] = [], total = 0
        for (path, hash) in manifest.files.sorted(by: { $0.key < $1.key }) {
            guard BackupEnvelope.safePath(path), result.count < 4096 else { throw CocoaError(.fileReadCorruptFile) }
            let url = entry.url.appendingPathComponent("files").appendingPathComponent(path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard size.isSymbolicLink != true, let bytes = size.fileSize, bytes <= BackupEnvelope.maximumPayload - total else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: url)
            guard data.count == bytes, Data(SHA256.hash(data: data)).base64EncodedString() == hash else { throw CocoaError(.fileReadCorruptFile) }
            total += data.count; result.append(BackupPayload(path: path, data: data))
        }
        return result
    }
    func restore(_ entry: Entry) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try entries().contains(where: { $0.url == entry.url }) else { throw CocoaError(.fileReadInvalidFileName) }
        let manifest = try PropertyListDecoder().decode(Manifest.self, from: Data(contentsOf: entry.url.appendingPathComponent("manifest.plist")))
        var validated: [String: Data] = [:]
        for (path, hash) in manifest.files {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\\"), !path.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let bytes = try Data(contentsOf: entry.url.appendingPathComponent("files").appendingPathComponent(path))
            guard Data(SHA256.hash(data: bytes)).base64EncodedString() == hash else { throw CocoaError(.fileReadCorruptFile) }
            validated[path] = bytes
        }
        // Preserve today's files before applying a historical checkpoint.
        try capture()
        for (path, bytes) in validated {
            let url = source.appendingPathComponent(path)
            var probe = source
            for part in path.split(separator: "/") {
                probe.appendPathComponent(String(part))
                guard (try? probe.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CocoaError(.fileReadCorruptFile) }
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
    }
}
