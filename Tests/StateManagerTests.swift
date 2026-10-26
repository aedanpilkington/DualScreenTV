import Foundation

// Fake core, real managers and real disk I/O. Exercise ownership and battery
// protection across asynchronous state completion, including failed restores.
@MainActor enum FakeCore {
    static var sram = Data(repeating: 0x11, count: 512)
    static var failedLoads = 0
}
func dstv_sram_size() -> Int { FakeCore.sram.count }
func dstv_copy_sram(_ destination: UnsafeMutableRawPointer?, _ size: Int) -> Int32 {
    guard let destination, size == FakeCore.sram.count else { return 0 }
    FakeCore.sram.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: size) }
    return 1
}
func dstv_restore_sram(_ source: UnsafeRawPointer?, _ size: Int) -> Int32 {
    guard let source, size == FakeCore.sram.count else { return 0 }
    FakeCore.sram = Data(bytes: source, count: size)
    return 1
}
func dstv_memory_size(_ region: UInt32) -> Int { region == 0 ? dstv_sram_size() : 0 }
func dstv_copy_memory(_ region: UInt32, _ destination: UnsafeMutableRawPointer?, _ size: Int) -> Int32 { region == 0 ? dstv_copy_sram(destination, size) : 0 }
func dstv_restore_memory(_ region: UInt32, _ source: UnsafeRawPointer?, _ size: Int) -> Int32 { region == 0 ? dstv_restore_sram(source, size) : 0 }
func dstv_state_size() -> Int { FakeCore.sram.count }
func dstv_save_state(_ destination: UnsafeMutableRawPointer?, _ size: Int) -> Int32 {
    dstv_copy_sram(destination, size)
}
func dstv_load_state(_ source: UnsafeRawPointer?, _ size: Int) -> Int32 {
    if FakeCore.failedLoads > 0 {
        FakeCore.failedLoads -= 1
        FakeCore.sram = Data(repeating: 0xFF, count: 512) // Partial failed restore.
        return 0
    }
    return dstv_restore_sram(source, size)
}

@main
struct StateManagerTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = root.appendingPathComponent("test.rom")
        try Data("manager test ROM".utf8).write(to: rom)
        let romID = try SaveDisk.identity(for: rom)
        let saves = try SaveManager(rom: rom, directory: root, temporary: false)
        let states = StateManager(directory: root.appendingPathComponent("States"), romID: romID, coreID: "test")
        let battery = SaveDisk(directory: root, romID: romID)
        let original = FakeCore.sram
        let saved = await withCheckedContinuation { continuation in
            states.save(slot: 1) { continuation.resume(returning: $0) }
        }
        assert(saved.contains("Saved state") && !states.busy)
        FakeCore.sram = Data(repeating: 0x22, count: 512)
        saves.flush()
        let newer = FakeCore.sram
        let loaded = await withCheckedContinuation { continuation in
            states.load(slot: 1, beforeRestore: { saves.flush() }, afterRestore: { saves.acceptStateBaseline() }) {
                continuation.resume(returning: $0)
            }
        }
        assert(loaded.contains("Loaded") && FakeCore.sram == original && !states.loading)
        saves.flush()
        let protected = try battery.load(expectedSize: 512)
        assert(protected?.data == newer) // Loading old SRAM didn't overwrite it.
        FakeCore.sram = Data(repeating: 0x33, count: 512)
        saves.flush()
        let legitimateSave = try battery.load(expectedSize: 512)
        assert(legitimateSave?.data == FakeCore.sram)
        let beforeFailure = FakeCore.sram
        FakeCore.failedLoads = 1
        let rejected = await withCheckedContinuation { continuation in
            states.load(slot: 1, beforeRestore: { saves.flush() }, afterRestore: { saves.acceptStateBaseline() }) {
                continuation.resume(returning: $0)
            }
        }
        assert(rejected.contains("previous game restored") && FakeCore.sram == beforeFailure && !states.failedRecovery)
        FakeCore.failedLoads = 2
        _ = await withCheckedContinuation { continuation in
            states.load(slot: 1, beforeRestore: { saves.flush() }, afterRestore: { saves.protectAfterFailedState() }) {
                continuation.resume(returning: $0)
            }
        }
        assert(states.failedRecovery && !states.busy)
        let blocked = await withCheckedContinuation { continuation in
            states.save(slot: 1) { continuation.resume(returning: $0) }
        }
        assert(blocked.contains("Relaunch"))
        saves.flush()
        let stillProtected = try battery.load(expectedSize: 512)
        assert(stillProtected?.data == beforeFailure)
        print("State managers: async save/load, battery protection, subsequent in-game save, rollback and failure protection passed")
    }
}
