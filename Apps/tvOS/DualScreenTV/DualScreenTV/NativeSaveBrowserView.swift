import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

struct NativeSaveBrowserView: View {
    let game: GameEntry
    let disk: GameLibraryDisk
    let coreHash: String
    let transferURL: String?
    @State private var core: String
    @State private var folder = ""
    @State private var files: [SaveFileEntry] = []
    @State private var sort = SaveSort.newest
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var message = ""
    @State private var selected: SaveFileEntry?
    @State private var showingImport = false
    private enum SaveSort: String, CaseIterable { case newest = "Newest", oldest = "Oldest", name = "Name", largest = "Largest" }
    init(game: GameEntry, disk: GameLibraryDisk, coreHash: String, transferURL: String?) {
        self.game = game; self.disk = disk; self.coreHash = coreHash; self.transferURL = transferURL
        _core = State(initialValue: game.system.saveCore)
    }
    private var cores: [String] { game.system == .nintendoDS ? ["melonDS", "Dust", "DeSmuME"] : [game.system.saveCore] }
    private var sortedFiles: [SaveFileEntry] {
        files.sorted { a, b in
            if a.directory != b.directory { return a.directory }
            switch sort {
            case .newest: if a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
            case .oldest: if a.modified != b.modified { return (a.modified ?? .distantPast) < (b.modified ?? .distantPast) }
            case .largest: if a.size != b.size { return a.size > b.size }
            case .name: break
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(game.title).font(.system(size: 38, weight: .semibold, design: .rounded))
                Text("Save files").font(.system(size: 30, weight: .semibold, design: .rounded))
                if cores.count > 1 {
                    Picker("Save core", selection: $core) { ForEach(cores, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    Text("Each DS core keeps separate saves. Choose the core used to play this game.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Sort", selection: $sort) { ForEach(SaveSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Text(folder.isEmpty ? core + " / Saves" : core + " / " + folder).font(.headline).lineLimit(2)
                    Spacer()
                    if !folder.isEmpty {
                        Button("Parent Folder") { folder = folder.split(separator: "/").dropLast().joined(separator: "/"); reload() }
                    }
                    Button("Refresh") { reload() }
                    Button("Import a Save") { showingImport = true }
                }.focusSection()
                if loading { ProgressView() }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                if !loading && files.isEmpty { Text("No save files in this folder yet. Save inside your game, then return here.").foregroundStyle(.secondary) }
                ForEach(sortedFiles, id: \.path) { file in
                    Button {
                        if file.directory { folder = file.path; reload() } else { selected = file }
                    } label: {
                        HStack(spacing: 24) {
                            Image(systemName: file.directory ? "folder.fill" : "doc.fill").frame(width: 44)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(file.name).font(.headline).lineLimit(2)
                                Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "Date unavailable").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(file.directory ? "Open folder" : ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption)
                            Image(systemName: "chevron.right")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Select a file to inspect it and export it. Backup History stores earlier copies separately.").font(.caption).foregroundStyle(.secondary)
            }.padding(64).frame(maxWidth: 1500).frame(maxWidth: .infinity)
        }.background(TVStudioBackground()).navigationTitle("Save Files").navigationBarHidden(false)
        .buttonStyle(TVStudioButtonStyle())
        .task { reload() }
        .onChange(of: core) { _ in folder = ""; reload() }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let file = selected {
                ScrollView { VStack(spacing: 24) {
                    Text(file.name).font(.title2).multilineTextAlignment(.center)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "Date unavailable").foregroundStyle(.secondary)
                    if let url = exportURL(file), let image = qr(url) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 350, height: 350).padding(16).background(.white)
                        Text("Scan to download this save to a device on your network.").font(.caption)
                        Text(file.portable ? "Export uses a portable .sav where supported. Use the matching game/version in your other emulator." : "This is a core-native file. Keep its name and folder when restoring it.").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Open Add/Edit Games to start the transfer service, then return here to export.") }
                    Button("Done") { selected = nil }
                }.padding(50).frame(maxWidth: 1100).frame(maxWidth: .infinity) }.background(TVStudioBackground()).buttonStyle(TVStudioButtonStyle())
            }
        }
        .sheet(isPresented: $showingImport) {
            VStack(spacing: 24) {
                Text("Bring your progress back").font(.title2)
                if let transferURL, let image = qr(transferURL) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 350, height: 350).padding(16).background(.white)
                    Text("Scan this code on a device on the same network. In Save explorer, choose this game and \(core), then import the matching save file.").multilineTextAlignment(.center)
                } else { Text("Open Add/Edit Games to start the transfer service.") }
                Text("Keep this page open during the transfer. Existing import validation and backup protection apply.").font(.caption).foregroundStyle(.secondary)
                Button("Done") { showingImport = false; reload() }
            }.padding(50).frame(maxWidth: 1100).background(TVStudioBackground()).buttonStyle(TVStudioButtonStyle())
        }
    }
    private func reload() {
        let selectedCore = core, path = folder
        let requestID = UUID(); loadID = requestID
        loading = true; message = ""; files = []
        let explorer = SaveExplorer(backups: SaveTransfer(library: disk, coreHash: coreHash))
        Task {
            let result = await Task.detached(priority: .utility) { Result { try explorer.list(id: game.id, core: selectedCore, path: path) } }.value
            guard loadID == requestID && core == selectedCore && folder == path else { return }
            loading = false
            switch result { case .success(let values): files = values; case .failure(let error): files = []; message = error.localizedDescription }
        }
    }
    private func exportURL(_ file: SaveFileEntry) -> String? {
        guard let transferURL, var url = URLComponents(string: transferURL + "/save-export") else { return nil }
        url.queryItems = [URLQueryItem(name: "id", value: game.id), URLQueryItem(name: "core", value: core), URLQueryItem(name: "path", value: file.path)]
        return url.url?.absoluteString
    }
    private func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
