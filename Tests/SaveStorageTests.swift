import Foundation

@main
struct SaveStorageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = root.appendingPathComponent("test.rom")
        try Data("test ROM".utf8).write(to: rom)
        let id = try SaveDisk.identity(for: rom)
        let repeatedID = try SaveDisk.identity(for: rom)
        assert(id.count == 64 && id == repeatedID)
        let disk = SaveDisk(directory: root, romID: id)
        let missing = try disk.load(expectedSize: 512)
        assert(missing == nil)
        let first = Data(repeating: 0x11, count: 512)
        let second = Data(repeating: 0x22, count: 512)
        try disk.write(first)
        try disk.write(second)
        let reopened = SaveDisk(directory: root, romID: id)
        let loaded = try reopened.load(expectedSize: 512)
        assert(loaded?.data == second && loaded?.recoveredBackup == false)
        try Data("corruption".utf8).write(to: disk.url)
        let recovery = SaveDisk(directory: root, romID: id)
        let recovered = try recovery.load(expectedSize: 512)
        assert(recovered?.data == first && recovered?.recoveredBackup == true)
        try recovery.write(second)
        let backup = disk.url.appendingPathExtension("backup")
        try FileManager.default.removeItem(at: disk.url)
        let backupOnly = try SaveDisk(directory: root, romID: id).load(expectedSize: 512)
        assert(backupOnly?.data == first)
        try Data("bad backup".utf8).write(to: backup)
        do {
            _ = try SaveDisk(directory: root, romID: id).load(expectedSize: 512)
            assertionFailure("Corrupt saves must throw")
        } catch {}
        try disk.write(second)
        do {
            _ = try SaveDisk(directory: root, romID: id).load(expectedSize: 256)
            assertionFailure("Mismatched SRAM size must throw")
        } catch {}
        // A valid plist with tampered PCM and an intact checksum must be refused.
        let bytes = try Data(contentsOf: disk.url)
        var plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: Any]
        plist["payload"] = first
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: disk.url)
        try FileManager.default.removeItem(at: backup)
        do {
            _ = try SaveDisk(directory: root, romID: id).load(expectedSize: 512)
            assertionFailure("Invalid checksum must throw")
        } catch {}
        let historySource = root.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: historySource, withIntermediateDirectories: true)
        let history = SaveHistory(source: historySource, destination: root.appendingPathComponent("history"))
        let nativeSave = historySource.appendingPathComponent("progress.sav")
        for byte in 0..<7 {
            try Data([UInt8(byte)]).write(to: nativeSave)
            try history.capture()
        }
        let historyEntries = try history.entries()
        assert(historyEntries.count == 5)
        try history.capture()
        let unchangedEntries = try history.entries(); assert(unchangedEntries.count == 5)
        try history.restore(historyEntries.last!)
        let restoredBytes = try Data(contentsOf: nativeSave); assert(restoredBytes == Data([2]))
        let newest = try history.entries().first!
        try Data([99]).write(to: newest.url.appendingPathComponent("files/progress.sav"))
        do { try history.restore(newest); assertionFailure("Corrupt history must be rejected") } catch {}
        let preservedBytes = try Data(contentsOf: nativeSave); assert(preservedBytes == Data([2]))
        print("Save history: bounded retention, unchanged deduplication, restore and corruption protection passed")
        print("Save storage: identity, missing, roundtrip, backup, corruption, size and checksum passed")
    }
}
