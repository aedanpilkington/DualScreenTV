import Foundation

@MainActor
final class SaveManager {
    private let disk: SaveDisk
    private let memoryRegion: UInt32
    var romID: String { disk.romID }
    private let io = DispatchQueue(label: "DualScreenTV.SaveIO", qos: .utility)
    private var committed: Data?
    private var candidate: Data?
    private var lastPoll = Date.distantPast
    private var writing = false
    private var generation = 0
    private var disabled = false
    private(set) var warning: String?

    convenience init(rom: URL, directory: URL, temporary: Bool) throws {
        try self.init(romID: SaveDisk.identity(for: rom), directory: directory, temporary: temporary)
    }

    init(romID: String, directory: URL, temporary: Bool, memoryRegion: UInt32 = 0) throws {
        self.memoryRegion = memoryRegion
        disk = SaveDisk(directory: directory, romID: romID)
        warning = temporary ? "Saves use temporary storage; external backup required." : nil
        let size = dstv_memory_size(memoryRegion)
        guard size > 0, size <= SaveDisk.maximumSRAM else {
            disabled = true
            warning = "Core exposes no supported SRAM; saves unavailable."
            return
        }
        do {
            if let loaded = try disk.load(expectedSize: size) {
                let restored = loaded.data.withUnsafeBytes {
                    dstv_restore_memory(memoryRegion, $0.baseAddress, $0.count)
                }
                guard restored == 1 else { throw CocoaError(.fileReadCorruptFile) }
                committed = loaded.data
                if loaded.recoveredBackup { warning = "Recovered the previous save checkpoint." }
                print("Restored \(size)-byte SRAM before first frame")
            } else {
                // Don't create a save merely because the initial blank SRAM exists.
                committed = snapshot()
                print("No local SRAM checkpoint for this ROM")
            }
        } catch {
            disabled = true
            warning = "Save unreadable; automatic writes disabled to protect existing files."
            print("\(warning!) \(error)")
        }
    }

    private func snapshot() -> Data? {
        let size = dstv_memory_size(memoryRegion)
        guard size > 0, size <= SaveDisk.maximumSRAM else { return nil }
        var bytes = Data(count: size)
        let copied = bytes.withUnsafeMutableBytes { dstv_copy_memory(memoryRegion, $0.baseAddress, $0.count) }
        return copied == 1 ? bytes : nil
    }

    func poll(now: Date = Date()) {
        guard !disabled, !writing, now.timeIntervalSince(lastPoll) >= 5 else { return }
        lastPoll = now
        guard let bytes = snapshot(), bytes != committed else {
            candidate = nil
            return
        }
        // Require two equal snapshots five seconds apart to avoid capturing
        // an in-game save while the game is still writing it.
        guard bytes == candidate else { candidate = bytes; return }
        writing = true
        generation += 1
        let generation = generation
        let disk = disk
        io.async { [weak self] in
            let result = Result { try disk.write(bytes) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.writing = false
                switch result {
                case .success: self.committed = bytes
                case .failure(let error):
                    self.warning = "Save checkpoint failed; see development log."
                    print("SRAM write failed: \(error)")
                }
            }
        }
    }

    // A state contains historical SRAM. Treat that as a new comparison baseline
    // without writing it over the battery checkpoint. A later in-game save can
    // still change SRAM and be checkpointed normally.
    func protectAfterFailedState() {
        generation += 1
        io.sync {}
        disabled = true
        writing = false
        warning = "State recovery failed; battery checkpoint protected. Relaunch the app."
    }

    func acceptStateBaseline() {
        generation += 1
        io.sync {}
        committed = snapshot()
        candidate = nil
        writing = false
        lastPoll = Date()
    }

    func flush() {
        guard !disabled, let bytes = snapshot(), bytes != committed || writing else { return }
        generation += 1
        // Lifecycle flush drains the single bounded writer before suspension.
        // A normal frame never waits for disk I/O.
        do {
            try io.sync { try disk.write(bytes) }
            committed = bytes
            writing = false
        } catch {
            writing = false
            warning = "Save checkpoint failed; see development log."
            print("SRAM lifecycle write failed: \(error)")
        }
    }
}
