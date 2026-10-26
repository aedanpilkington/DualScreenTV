import Foundation
import CryptoKit

nonisolated enum GameSystem: String, Codable, CaseIterable {
    case nintendoDS, nintendo3DS, gameBoy, gameBoyColor, gameBoyAdvance, psp
    var title: String {
        switch self {
        case .nintendoDS: "Nintendo DS"
        case .nintendo3DS: "Nintendo 3DS"
        case .gameBoy: "Game Boy"
        case .gameBoyColor: "Game Boy Color"
        case .gameBoyAdvance: "Game Boy Advance"
        case .psp: "PlayStation Portable"
        }
    }
    var dualScreen: Bool { self == .nintendoDS || self == .nintendo3DS }
    var coreIdentifier: EmulatorCoreIdentifier {
        switch self { case .nintendoDS: .melonDS; case .nintendo3DS: .azahar; case .psp: .ppsspp; default: .mgba }
    }
    var dynamicCore: String? {
        switch self { case .nintendoDS: nil; case .nintendo3DS: "azahar"; case .psp: "ppsspp"; default: "mgba" }
    }
    var saveCore: String {
        switch self { case .nintendoDS: "melonDS"; case .nintendo3DS: "3DS"; case .psp: "PSP"; default: "mGBA" }
    }
}
nonisolated enum EmulatorCoreIdentifier: String, Codable {
    case melonDS = "melonds-ds-1.1.8", azahar = "azahar-2126.2", mgba = "mgba-0.10.5", ppsspp = "ppsspp-ir-vulkan-1"
}
nonisolated enum GameAvailability: String, Codable { case available, needsImport }
nonisolated struct GameEntry: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    let system: GameSystem
    let core: EmulatorCoreIdentifier
    var filename: String
    let imported: Date
    var lastPlayed: Date?
    var favourite = false
    var availability = GameAvailability.available
    var artwork: String?
    var artworkVersion: Int?
    var sramSize: Int?
    var stateSize: Int?
    var storedExtension: String?
    var saveNamespace: String { id }
    var stateNamespace: String { id }
}
nonisolated enum LibraryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}
nonisolated enum GameIdentity {
    static func valid(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func deepLink(_ url: URL) -> String? {
        guard url.scheme == "dualscreentv", url.host == "game", url.query == nil,
              url.fragment == nil, url.user == nil, url.port == nil else { return nil }
        let id = String(url.path.dropFirst())
        return valid(id) ? id : nil
    }
    static func link(_ id: String) -> URL { URL(string: "dualscreentv://game/" + id)! }
}
nonisolated enum ROMValidation {
    static let maximumSize = 4 * 1024 * 1024 * 1024
    static let extensions: Set<String> = ["nds", "cci", "3ds", "cxi", "3dsx", "gb", "gbc", "gba", "iso", "cso", "pbp"]
    static func system(for filename: String) throws -> GameSystem {
        let ext = (try self.filename(filename) as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { throw LibraryError.invalid("Use a supported DS, 3DS, GB, GBC, GBA or PSP game file.") }
        switch ext {
        case "nds": return .nintendoDS
        case "gb": return .gameBoy
        case "gbc": return .gameBoyColor
        case "gba": return .gameBoyAdvance
        case "iso", "cso", "pbp": return .psp
        default: return .nintendo3DS
        }
    }
    static func detectedSystem(_ url: URL, filename: String) throws -> GameSystem {
        let system = try self.system(for: filename)
        guard system == .gameBoy else { return system }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: 0x143)
        let flag = try file.read(upToCount: 1)?.first ?? 0
        return flag & 0x80 != 0 ? .gameBoyColor : .gameBoy
    }
    static func filename(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 240, !name.contains(".."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryError.invalid("Invalid filename. Use a plain filename without folders.")
        }
        return name
    }
    static func validate(_ url: URL, filename: String) throws {
        let name = try self.filename(filename)
        let system = try self.system(for: name)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 512, size <= (system == .nintendoDS ? 512 * 1024 * 1024 : maximumSize) else { throw LibraryError.invalid("Unsupported game size. DS is limited to 512 MB; other supported formats are limited to 4 GB, with additional cartridge checks.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 512) ?? Data()
        func word(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 | Int(header[offset + $1]) << ($1 * 8) } }
        guard header.count == 512 else { throw LibraryError.invalid("Incomplete DS header.") }
        if !system.dualScreen {
            switch system {
            case .gameBoy, .gameBoyColor:
                guard size >= 32768, header[0x104] == 0xce, header[0x105] == 0xed else { throw LibraryError.invalid("Invalid Game Boy cartridge header.") }
            case .gameBoyAdvance:
                guard size >= 1024, size <= 32 * 1024 * 1024, header[0xb2] == 0x96 else { throw LibraryError.invalid("Invalid GBA cartridge header.") }
            case .psp:
                let ext = (name as NSString).pathExtension.lowercased()
                if ext == "cso" { guard header.prefix(4) == Data("CISO".utf8) else { throw LibraryError.invalid("Invalid compressed PSP image.") } }
                else if ext == "pbp" { guard header.prefix(4) == Data([0,0x50,0x42,0x50]) else { throw LibraryError.invalid("Invalid PSP executable package.") } }
                else {
                    try handle.seek(toOffset: 32769)
                    guard try handle.read(upToCount: 5) == Data("CD001".utf8) else { throw LibraryError.invalid("Invalid PSP ISO image.") }
                }
            default: break
            }
            return
        }
        if system == .nintendo3DS {
            let ext = (name as NSString).pathExtension.lowercased()
            let magic = String(data: header[0x100..<0x104], encoding: .ascii)
            if ext == "3dsx" {
                guard header.prefix(4) == Data("3DSX".utf8), header[4] >= 0x20 else { throw LibraryError.invalid("Invalid 3DS homebrew header.") }
                return
            }
            guard magic == "NCCH" || magic == "NCSD" else { throw LibraryError.invalid("Invalid 3DS container. Use a decrypted game dump or .3dsx homebrew.") }
            let units = word(0x104)
            guard units > 0, units <= size / 512 else { throw LibraryError.invalid("Incomplete 3DS container.") }
            if magic == "NCCH" {
                guard header[0x18f] & 4 != 0 else { throw LibraryError.invalid("This 3DS game is encrypted. Import a decrypted dump.") }
            } else {
                // Validate every occupied cartridge partition and its crypto flags.
                for i in 0..<8 {
                    let start = word(0x120 + i * 8) * 512, length = word(0x124 + i * 8) * 512
                    if length == 0 { continue }
                    guard start >= 512, start <= size, length <= size - start else { throw LibraryError.invalid("Incomplete 3DS partition.") }
                    try handle.seek(toOffset: UInt64(start))
                    let partition = try handle.read(upToCount: 512) ?? Data()
                    guard partition.count == 512, partition[0x100..<0x104] == Data("NCCH".utf8), partition[0x18f] & 4 != 0 else { throw LibraryError.invalid("Use a decrypted 3DS cartridge dump.") }
                }
            }
            return
        }
        // Check executable regions before passing an upload to the native core.
        for offset in [0x20, 0x30] {
            let start = word(offset), length = word(offset + 12)
            guard start >= 512, length > 0, start <= size, length <= size - start else {
                throw LibraryError.invalid("Invalid or incomplete DS ROM executable regions.")
            }
        }
    }
}

// All mutations serialize under this lock. The network queue and library worker
// share this store; no disk operation runs alongside emulator frame work.
nonisolated final class GameLibraryDisk: @unchecked Sendable {
    let root: URL
    let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    static let metadataKey = "library.entries.v1"
    static let maximumGames = 300
    init(root: URL, defaults: UserDefaults = .standard) throws {
        self.root = root; self.defaults = defaults
        try FileManager.default.createDirectory(at: romDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: uploadDirectory, includingPropertiesForKeys: nil)
            where url.pathExtension == "upload" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: url)
        }
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        upgradeArtwork()
    }
    var romDirectory: URL { root.appendingPathComponent("ROMs", isDirectory: true) }
    var uploadDirectory: URL { root.appendingPathComponent("Transfers", isDirectory: true) }
    var savesDirectory: URL { root.appendingPathComponent("Saves", isDirectory: true) }
    var statesDirectory: URL { root.appendingPathComponent("States", isDirectory: true) }
    var artworkDirectory: URL { root.appendingPathComponent("Artwork", isDirectory: true) }
    func artworkURL(_ name: String?) -> URL? {
        guard let name, GameArtwork.validFilename(name) else { return nil }
        return artworkDirectory.appendingPathComponent(name)
    }
    func setArtwork(_ temporary: URL, id: String) throws {
        // Decode on the transfer worker, then serialize metadata/file mutations.
        let picture = try GameArtwork.normalize(temporary)
        lock.lock(); defer { lock.unlock() }
        guard try entries().contains(where: { $0.id == id }) else { throw LibraryError.invalid("Unknown game.") }
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try picture.data.write(to: artworkDirectory.appendingPathComponent(picture.name), options: .atomic)
        try update(id) { $0.artwork = picture.name; $0.artworkVersion = 2 }
        pruneArtwork()
    }
    private func upgradeArtwork() {
        guard let games = try? entries() else { return }
        for game in games where game.artwork != nil && (game.artworkVersion ?? 1) < 2 {
            guard let source = artworkURL(game.artwork), FileManager.default.fileExists(atPath: source.path) else { continue }
            do {
                let picture = try GameArtwork.upgradeFittedPicture(source)
                try picture.data.write(to: artworkDirectory.appendingPathComponent(picture.name), options: .atomic)
                try update(game.id) { $0.artwork = picture.name; $0.artworkVersion = 2 }
            } catch { print("Artwork upgrade skipped: \(error.localizedDescription)") }
        }
        pruneArtwork()
    }
    func removeArtwork(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try update(id) { $0.artwork = nil }
        pruneArtwork()
    }
    private func pruneArtwork() {
        guard let games = try? entries(), let files = try? FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil) else { return }
        let used = Set(games.compactMap(\.artwork))
        for file in files where GameArtwork.validFilename(file.lastPathComponent) && !used.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func romURL(_ id: String) throws -> URL {
        guard GameIdentity.valid(id) else { throw LibraryError.invalid("Invalid game ID.") }
        lock.lock(); defer { lock.unlock() }
        let bytes = defaults.data(forKey: Self.metadataKey)
        guard (bytes?.count ?? 0) <= 350_000 else { throw LibraryError.invalid("Library metadata exceeds its supported size.") }
        let games = try bytes.map { try PropertyListDecoder().decode([GameEntry].self, from: $0) } ?? []
        let ext = games.first(where: { $0.id == id })?.storedExtension ?? "nds"
        return try storedROMURL(id, extension: ext)
    }
    private func storedROMURL(_ id: String, extension ext: String) throws -> URL {
        guard GameIdentity.valid(id), ROMValidation.extensions.contains(ext) else { throw LibraryError.invalid("Invalid stored game path.") }
        return romDirectory.appendingPathComponent(id + "." + ext)
    }
    func entries() throws -> [GameEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let bytes = defaults.data(forKey: Self.metadataKey) else { return [] }
        guard bytes.count <= 350_000 else { throw LibraryError.invalid("Library metadata exceeds its supported size.") }
        var entries = try PropertyListDecoder().decode([GameEntry].self, from: bytes)
        guard entries.count <= Self.maximumGames, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ GameIdentity.valid($0.id) && $0.title.utf8.count <= 240 }) else { throw LibraryError.invalid("Invalid library metadata.") }
        for index in entries.indices {
            let exists = FileManager.default.fileExists(atPath: try storedROMURL(entries[index].id, extension: entries[index].storedExtension ?? "nds").path)
            entries[index].availability = exists ? .available : .needsImport
        }
        return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func persist(_ entries: [GameEntry]) throws {
        guard entries.count <= Self.maximumGames else { throw LibraryError.invalid("Library is full (300 games).") }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let bytes = try encoder.encode(entries)
        guard bytes.count <= 350_000 else { throw LibraryError.invalid("Library metadata is full.") }
        defaults.set(bytes, forKey: Self.metadataKey)
    }
    @discardableResult func importROM(_ temporary: URL, filename: String, streamedIdentity: String? = nil) throws -> GameEntry {
        lock.lock(); defer { lock.unlock() }
        try ROMValidation.validate(temporary, filename: filename)
        // The transfer server hashes every written byte as it arrives. Other
        // import callers still hash the completed file here.
        if let streamedIdentity, !GameIdentity.valid(streamedIdentity) { throw LibraryError.invalid("Invalid game identity.") }
        let id = try streamedIdentity ?? SaveDisk.identity(for: temporary)
        var games = try entries()
        let existing = games.firstIndex { $0.id == id }
        guard existing != nil || games.count < Self.maximumGames else { throw LibraryError.invalid("Library is full.") }
        let system = try ROMValidation.detectedSystem(temporary, filename: filename)
        let ext = system == .nintendoDS ? "nds" : ((filename as NSString).pathExtension.lowercased() == "3ds" ? "cci" : (filename as NSString).pathExtension.lowercased())
        let storedExtension = existing.map { games[$0].storedExtension ?? "nds" } ?? ext
        let destination = romDirectory.appendingPathComponent(id + "." + storedExtension)
        // Upload staging and final ROMs share a filesystem; rename is atomic.
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: temporary, to: destination) }
        var game = existing.map { games[$0] } ?? GameEntry(id: id,
            title: String((filename as NSString).deletingPathExtension.prefix(160)), system: system,
            core: system.coreIdentifier, filename: filename, imported: Date())
        game.storedExtension = storedExtension
        game.filename = filename; game.availability = .available
        if let existing { games[existing] = game } else { games.append(game) }
        try persist(games)
        return game
    }
    func update(_ id: String, _ edit: (inout GameEntry) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var games = try entries()
        guard let index = games.firstIndex(where: { $0.id == id }) else { throw LibraryError.invalid("Game is no longer in the library.") }
        edit(&games[index]); try persist(games)
    }
    func rename(_ id: String, to name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryError.invalid("Enter a game name.") }
        guard title.utf8.count <= 240 else { throw LibraryError.invalid("Name is too long. Try a shorter name.") }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryError.invalid("Use a single line for the game name.")
        }
        try update(id) { $0.title = title }
    }
    func deleteGame(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var games = try entries()
        guard games.contains(where: { $0.id == id }) else { throw LibraryError.invalid("Game not found.") }
        let url = try romURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        games.removeAll { $0.id == id }
        try persist(games)
        // Saves and states remain available if the same ROM is imported again.
    }
    func removeROM(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let url = try romURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try update(id) { $0.availability = .needsImport }
        // Metadata, SRAM and state namespaces are intentionally retained.
    }
}

nonisolated struct ShelfGame: Codable, Equatable {
    let id: String
    let title: String
    let favourite: Bool
    let lastPlayed: Date?
    var artwork: String?
    static func snapshot(_ games: [GameEntry]) -> [ShelfGame] {
        games.filter { $0.availability == .available && ($0.favourite || $0.lastPlayed != nil) }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(20).map { ShelfGame(id: $0.id, title: $0.title, favourite: $0.favourite, lastPlayed: $0.lastPlayed, artwork: $0.artwork) }
    }
}
