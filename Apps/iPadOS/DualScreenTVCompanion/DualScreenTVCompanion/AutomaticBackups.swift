import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security
import Combine

private struct BackupPairing: Codable {
    let address: String
    let sourceID: String
    let token: String
}
private enum BackupCredential {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "DualScreenTV") + ".automatic-backup", kSecAttrAccount as String: "paired-tv"] }
    static func load() -> BackupPairing? {
        var query = query; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BackupPairing.self, from: data)
    }
    static func save(_ value: BackupPairing) throws {
        let bytes = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = bytes
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BackupFailure.invalid("Could not securely remember this TV.") }; return
        }
        guard status == errSecSuccess else { throw BackupFailure.invalid("Could not securely remember this TV.") }
    }
    static func forget() { SecItemDelete(query as CFDictionary) }
}
nonisolated private final class BackupNetwork: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > BackupEnvelope.maximumEncoded || totalBytesExpectedToWrite > BackupEnvelope.maximumEncoded { downloadTask.cancel() }
    }
}
@MainActor final class AutomaticBackupModel: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var devices: [String: URL] = [:]
    @Published var address = ""
    @Published var paired = false
    @Published var busy = false
    @Published var message = "Pair once to keep automatic save backups on this device."
    @Published var entries: [BackupVault.Entry] = []
    @Published var lastVerified: Date?
    @Published var exportedFile: URL?
    @Published var restoreSelection: BackupVault.Entry?
    @Published var enabled = UserDefaults.standard.object(forKey: "backup.enabled") as? Bool ?? true
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var timer: Task<Void, Never>?
    private var credential: BackupPairing?
    private var active = false
    private let network = BackupNetwork()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config, delegate: network, delegateQueue: nil)
    }()
    private var vault: BackupVault {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return BackupVault(root: base.appendingPathComponent("DualScreenTV/AutomaticBackups", isDirectory: true))
    }
    override init() {
        super.init(); browser.delegate = self
        credential = BackupCredential.load(); paired = credential != nil; address = credential?.address ?? ""
        if let value = UserDefaults.standard.object(forKey: "backup.lastVerified") as? Date { lastVerified = value }
        Task { await reloadEntries() }
    }
    func activate(_ value: Bool) {
        active = value; timer?.cancel(); timer = nil
        browser.stop(); services.forEach { $0.stop() }; services.removeAll(); devices.removeAll()
        guard value else { return }
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.enabled && self.credential != nil { await self.backUp() }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "backup.enabled")
        message = value ? "Automatic backups enabled. Waiting for the TV library." : "Automatic backups paused. Existing copies are kept."
        if value { Task { await backUp() } }
    }
    func forget() {
        guard !busy else { return }
        BackupCredential.forget(); credential = nil; paired = false; lastVerified = nil
        UserDefaults.standard.removeObject(forKey: "backup.lastVerified")
        message = "TV forgotten. Your existing backups are still on this device."
    }
    private func origin() throws -> URL {
        guard let credential, let url = CompanionTransferAddress.parse(credential.address) else { throw BackupFailure.invalid("Pair this device with Apple TV first.") }
        return url
    }
    private func request(_ path: String, token: String? = nil) throws -> URLRequest {
        let origin = try origin()
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host, url.port == origin.port else { throw BackupFailure.invalid("Invalid TV address.") }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func response(_ request: URLRequest) async throws -> Data {
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let length = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if response.mimeType == "text/plain", length <= 4096,
               let data = try? Data(contentsOf: file), let message = String(data: data, encoding: .utf8) {
                throw BackupFailure.invalid(String(message.prefix(240)))
            }
            throw BackupFailure.invalid("TV unavailable or pairing expired. Keep it on the library screen; pair again if needed.")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= BackupEnvelope.maximumEncoded else { throw BackupFailure.invalid("Backup response is too large.") }
        return try await Task.detached(priority: .utility) { try Data(contentsOf: file) }.value
    }
    func pair(code: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }), let origin = CompanionTransferAddress.parse(address) else { throw BackupFailure.invalid("Choose your TV and enter the six-digit Add/Edit Games code.") }
            var request = URLRequest(url: origin.appendingPathComponent("backup-pair")); request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(["code": code, "name": String(UIDevice.current.name.prefix(40))])
            let reply = try JSONDecoder().decode(BackupPairReply.self, from: await response(request))
            guard UUID(uuidString: reply.sourceID) != nil, BackupEnvelope.isHash(reply.token) else { throw BackupFailure.invalid("Invalid pairing response.") }
            let value = BackupPairing(address: origin.absoluteString, sourceID: reply.sourceID, token: reply.token)
            try BackupCredential.save(value); credential = value; paired = true
            lastVerified = nil; UserDefaults.standard.removeObject(forKey: "backup.lastVerified")
            message = "TV paired. Your first backup is starting…"
        } catch { message = error.localizedDescription; return }
        busy = false
        await backUp()
    }
    func backUp() async {
        guard !busy, active, enabled, let credential else { return }
        busy = true; defer { busy = false }
        do {
            message = "Checking saved progress…"
            let catalog = try JSONDecoder().decode(BackupCatalogResponse.self, from: await response(request("/automatic-backups/catalog", token: credential.token)))
            guard catalog.sourceID == credential.sourceID, catalog.items.count <= 12_000 else { throw BackupFailure.invalid("This address belongs to a different TV. Pair again.") }
            let vault = vault
            var copied = 0
            for item in catalog.items {
                try Task.checkCancellation()
                guard active else { return }
                guard item.sourceID == credential.sourceID, BackupEnvelope.isHash(item.id), BackupEnvelope.isHash(item.revision) else { throw BackupFailure.invalid("Invalid backup listing.") }
                if await Task.detached(priority: .utility, operation: { vault.contains(item) }).value { continue }
                message = "Backing up \(item.title)…"
                let data = try await response(request("/automatic-backups/download?id=\(item.id)&revision=\(item.revision)", token: credential.token))
                try await Task.detached(priority: .utility) { try vault.store(data, expected: item) }.value
                copied += 1
            }
            await reloadEntries()
            if catalog.items.isEmpty {
                message = "No saved progress found. Save in game, then return to the TV library. Your existing backups are kept."
            } else {
                lastVerified = Date(); UserDefaults.standard.set(lastVerified, forKey: "backup.lastVerified")
                message = copied == 0 ? "Your backups on this device are up to date." : "\(copied) backup\(copied == 1 ? "" : "s") saved and verified on this device."
            }
        } catch {
            message = error is CancellationError ? "Backup paused. Existing copies are safe." : "Waiting for the TV library. \(error.localizedDescription) Existing backups are kept."
        }
    }
    func importBackup(_ url: URL) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let imported = BackupVault(root: vault.root.appendingPathComponent("Imported"))
        do {
            try await Task.detached(priority: .utility) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= BackupEnvelope.maximumEncoded else { throw BackupFailure.invalid("Backup is too large.") }
                let bytes = try Data(contentsOf: url), envelope = try BackupEnvelope.decode(bytes)
                try imported.store(bytes, expected: envelope.item)
            }.value
            await reloadEntries(); message = "Backup imported and verified on this device."
        } catch { message = "Could not import backup: \(error.localizedDescription)" }
    }
    func restore(code: String) async {
        guard !busy, let selection = restoreSelection else { return }; busy = true; defer { busy = false }
        do {
            guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw BackupFailure.invalid("Enter the current Add/Edit Games code.") }
            let bytes = try await Task.detached(priority: .utility) {
                let size = try selection.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= BackupEnvelope.maximumEncoded else { throw BackupFailure.invalid("Backup is too large.") }
                let data = try Data(contentsOf: selection.url); _ = try BackupEnvelope.decode(data); return data
            }.value
            var pair = try request("/pair"); pair.httpMethod = "POST"; pair.httpBody = Data(code.utf8)
            guard let path = String(data: try await response(pair), encoding: .utf8), path.count == 65, path.first == "/", path.dropFirst().allSatisfy(\.isHexDigit) else { throw BackupFailure.invalid("Pairing failed.") }
            var restore = try request(path + "/automatic-restore"); restore.httpMethod = "POST"; restore.httpBody = bytes
            _ = try await response(restore)
            message = "Backup restored to Apple TV. Reopen the game to continue."
            restoreSelection = nil
        } catch { message = "Restore failed: \(error.localizedDescription)" }
    }
    private func reloadEntries() async {
        let vault = vault
        do { entries = try await Task.detached(priority: .utility) {
            try (vault.entries() + BackupVault(root: vault.root.appendingPathComponent("Imported")).entries()).sorted { $0.item.created > $1.item.created }
        }.value }
        catch { message = "Cannot read backups on this device: \(error.localizedDescription)" }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name.hasPrefix("DualScreenTV") else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 8)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        var parts = URLComponents(); parts.scheme = "http"; parts.host = host; parts.port = sender.port
        if let url = parts.url, CompanionTransferAddress.parse(url.absoluteString) != nil { devices[sender.name] = url }
    }
}

struct AutomaticBackupsView: View {
    @ObservedObject var model: AutomaticBackupModel
    @State private var code = ""
    @State private var restoreCode = ""
    @State private var importing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("A little peace of mind.").font(.largeTitle.bold())
                    Text("Automatic save backups").font(.title2)
                    Text("Keep the companion open on your Mac or iPad. After saving, return to the TV library so its save files can be backed up safely. Checks run every minute on your local network.").foregroundStyle(.secondary)
                    if !model.paired {
                        ForEach(model.devices.keys.sorted(), id: \.self) { name in
                            Button(name) { model.address = model.devices[name]?.absoluteString ?? "" }.buttonStyle(StudioButtonStyle())
                        }
                        TextField("Apple-TV.local:8765", text: $model.address).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        TextField("Add/Edit Games code", text: $code).keyboardType(.numberPad)
                            .padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        Button("Pair for automatic backups") { Task { await model.pair(code: code); code = "" } }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(model.busy)
                    } else {
                        Toggle("Back up automatically", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                        Button("Back up now") { Task { await model.backUp() } }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(model.busy || !model.enabled)
                        Button("Forget this TV") { model.forget() }.disabled(model.busy)
                    }
                    Text(model.message).font(.callout)
                    if let date = model.lastVerified { Text("Last verified off TV: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    Text("Saved on this device").font(.title2.bold())
                    Button("Import an exported backup") { importing = true }.disabled(model.busy)
                    Text("Up to five automatic versions per save set or state slot. TV deletions never remove these copies. Removing this companion app can remove its backups; export important copies too. This feature does not use iCloud sync.").font(.callout).foregroundStyle(.secondary)
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.item.title).font(.headline)
                            Text("\(entry.item.core) · \(entry.item.kind == "saves" ? "In-game saves" : "Save state " + String(entry.item.kind.dropFirst(6))) · \(entry.item.created.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                ShareLink(item: entry.url) { Label("Export", systemImage: "square.and.arrow.up") }
                                Button("Restore to TV") { restoreCode = ""; model.restoreSelection = entry }.disabled(model.busy || !model.paired)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
                    }
                }.padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }.background(Color(white: 0.045)).navigationTitle("Save backups")
            .sheet(isPresented: $importing) {
                SaveBackupPicker { url in
                    importing = false
                    if let url { Task { await model.importBackup(url) } }
                }
            }
            .sheet(isPresented: Binding(get: { model.restoreSelection != nil }, set: { if !$0 { model.restoreSelection = nil } })) {
                VStack(spacing: 24) {
                    Text("Restore this backup?").font(.title.bold())
                    Text("This replaces this game's saved progress on Apple TV. Keep the TV on its library screen and enter its current Add/Edit Games code. Re-import the same ROM first if it was removed.")
                    TextField("Current six-digit TV code", text: $restoreCode).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    Button("Replace TV saves with this backup") { Task { await model.restore(code: restoreCode); restoreCode = "" } }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(model.busy)
                    Text(model.message).font(.callout)
                    Button("Cancel") { model.restoreSelection = nil }.disabled(model.busy)
                }.padding(32).presentationDetents([.medium, .large])
            }
        }.preferredColorScheme(.dark)
    }
}

private struct SaveBackupPicker: UIViewControllerRepresentable {
    let selected: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL?) -> Void
        init(selected: @escaping (URL?) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
    }
}
