import Foundation

@MainActor
final class StateManager {
    private let disk: StateDisk
    private let io = DispatchQueue(label: "DualScreenTV.StateIO", qos: .utility)
    private(set) var busy = false
    private(set) var loading = false
    private(set) var failedRecovery = false

    init(directory: URL, romID: String, coreID: String) {
        disk = StateDisk(directory: directory, romID: romID, coreID: coreID)
    }
    private func snapshot() -> Data? {
        let size = dstv_state_size()
        guard size > 0, size <= StateDisk.maximumSize else { return nil }
        var bytes = Data(count: size)
        return bytes.withUnsafeMutableBytes { dstv_save_state($0.baseAddress, $0.count) } == 1 ? bytes : nil
    }
    func save(slot: Int, thumbnail: Data? = nil, completion: @escaping @MainActor (String) -> Void) {
        guard !failedRecovery else { completion("Relaunch before using save states again"); return }
        guard !busy else { completion("State operation already in progress"); return }
        guard let bytes = snapshot() else { completion("Save states unavailable for this core/game"); return }
        busy = true
        let disk = disk
        io.async { [weak self] in
            let result = Result {
                try disk.write(bytes, slot: slot)
                // A missing thumbnail must never turn a valid state into a failure.
                try? disk.thumbnail(thumbnail, slot: slot)
            }
            Task { @MainActor [weak self] in
                self?.busy = false
                switch result {
                case .success: completion("Saved state to slot \(slot)")
                case .failure(let error):
                    print("State write failed: \(error)")
                    completion("State save failed; existing slot retained where possible")
                }
            }
        }
    }
    func load(slot: Int, beforeRestore: () -> Void,
              afterRestore: @escaping @MainActor () -> Void,
              completion: @escaping @MainActor (String) -> Void) {
        guard !failedRecovery else { completion("Relaunch before using save states again"); return }
        guard !busy else { completion("State operation already in progress"); return }
        guard let rollback = snapshot() else { completion("Save states unavailable for this core/game"); return }
        beforeRestore()
        busy = true
        loading = true
        let disk = disk
        io.async { [weak self] in
            let result = Result { try disk.load(slot: slot, size: rollback.count) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.busy = false; self.loading = false }
                switch result {
                case .success(let loaded):
                    let restored = loaded.payload.withUnsafeBytes { dstv_load_state($0.baseAddress, $0.count) }
                    if restored == 1 {
                        afterRestore()
                        completion("Loaded \(loaded.backup ? "backup " : "")state from slot \(slot)")
                    } else {
                        let recovered = rollback.withUnsafeBytes { dstv_load_state($0.baseAddress, $0.count) }
                        self.failedRecovery = recovered != 1
                        afterRestore()
                        completion(recovered == 1 ? "State rejected; previous game restored" : "State restore failed; pause and relaunch the app")
                    }
                case .failure(let error):
                    print("State read failed: \(error)")
                    completion("No valid compatible state in slot \(slot)")
                }
            }
        }
    }
    func slots(completion: @escaping @MainActor ([StateSlotInfo]) -> Void) {
        let disk = disk
        io.async { let slots = disk.slots(); Task { @MainActor in completion(slots) } }
    }
    func flush() { io.sync {} } // Drain a pending write before tvOS suspension.
}
