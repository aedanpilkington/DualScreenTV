#if DEBUG
import Foundation

// Explicit opt-in device check, never enabled by native preferences. Uses a
// disposable directory, not a user's slot or battery save. The owner calls this
// between frames with audio stopped. No core data escapes the main actor.
@MainActor
enum CoreSmokeCheck {
    static func run() -> String {
        let size = dstv_state_size()
        guard size > 0, size <= StateDisk.maximumSize else { return "Core smoke: serialization unavailable" }
        var original = Data(count: size)
        guard original.withUnsafeMutableBytes({ dstv_save_state($0.baseAddress, $0.count) }) == 1 else {
            return "Core smoke: serialize failed"
        }
        let sramSize = dstv_sram_size()
        var sramBefore = Data(count: sramSize)
        guard sramSize == 0 || sramBefore.withUnsafeMutableBytes({ dstv_copy_sram($0.baseAddress, $0.count) }) == 1 else {
            return "Core smoke: SRAM snapshot failed"
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StateSmoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if sramSize > 0 {
                let battery = SaveDisk(directory: directory, romID: "smoke-rom")
                try battery.write(sramBefore)
                guard try battery.load(expectedSize: sramSize)?.data == sramBefore else { return "Core smoke: battery disk roundtrip mismatch" }
            }
            let disk = StateDisk(directory: directory, romID: "smoke-rom", coreID: "smoke-core")
            try disk.write(original, slot: 1)
            let loaded = try disk.load(slot: 1, size: size)
            guard loaded.payload == original else { return "Core smoke: disk roundtrip mismatch" }
            _ = dstv_run_one_frame()
            guard loaded.payload.withUnsafeBytes({ dstv_load_state($0.baseAddress, $0.count) }) == 1 else {
                _ = original.withUnsafeBytes { dstv_load_state($0.baseAddress, $0.count) }
                return "Core smoke: unserialize failed"
            }
            var sramAfter = Data(count: sramSize)
            let copied = sramAfter.withUnsafeMutableBytes { dstv_copy_sram($0.baseAddress, $0.count) }
            return "Core smoke: state \(size) bytes; serialize/disk/unserialize passed; SRAM unchanged=\((sramSize == 0 || copied == 1) && sramBefore == sramAfter)"
        } catch {
            return "Core smoke: disk failed: \(error)"
        }
    }
}
#endif
