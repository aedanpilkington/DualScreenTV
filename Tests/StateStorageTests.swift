import Foundation

@main
struct StateStorageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = StateDisk(directory: root, romID: "rom-a", coreID: "core-a")
        let first = Data(repeating: 0x12, count: 4096)
        let second = Data(repeating: 0x34, count: 4096)
        func refuses(_ operation: () throws -> Void) {
            do { try operation(); assertionFailure("Invalid state must be rejected") } catch {}
        }
        refuses { _ = try disk.load(slot: 1, size: 4096) }
        for slot in 1...10 {
            try disk.write(first, slot: slot)
            let read = try disk.load(slot: slot, size: 4096)
            assert(read.payload == first && !read.backup)
        }
        refuses { try disk.write(first, slot: 0) }
        refuses { try disk.write(first, slot: 11) }
        refuses { try disk.write(Data(), slot: 1) }
        refuses { _ = try disk.load(slot: 1, size: 20) }
        refuses { _ = try StateDisk(directory: root, romID: "rom-a", coreID: "core-b").load(slot: 1, size: 4096) }
        refuses { _ = try StateDisk(directory: root, romID: "rom-b", coreID: "core-a").load(slot: 1, size: 4096) }
        try disk.write(second, slot: 1)
        let url = try disk.url(slot: 1)
        var archive = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
        archive["payload"] = first // Tamper without updating the checksum.
        try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0).write(to: url)
        let recovered = try disk.load(slot: 1, size: 4096)
        assert(recovered.backup && recovered.payload == first)
        try disk.write(second, slot: 1)
        try FileManager.default.removeItem(at: url)
        let preserved = try disk.load(slot: 1, size: 4096)
        assert(preserved.backup && preserved.payload == first)
        let otherSlot = try disk.load(slot: 2, size: 4096)
        assert(otherSlot.payload == first && !otherSlot.backup)
        print("State storage: ten slots, ROM/core isolation, size/checksum validation, atomic rotation and recovery passed")
    }
}
