import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins
import TVServices
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published var games: [GameEntry] = []
    @Published var message: String?
    @Published var busy = false
    @Published private(set) var stoppingTransfer = false
    @Published var transferStatus = "Starting local transfer…"
    @Published var transferURLs: [String] = []
    @Published var transferActive = false
    let transferCode = String(format: "%06u", UInt32.random(in: 0...999_999))
    var transferQRURL: String? {
        guard let base = transferURLs.first, let server else { return nil }
        return base + "/" + server.token
    }
    private(set) var disk: GameLibraryDisk?
    private(set) var directories: StorageDirectories?
    private(set) var coreHash = ""
    private var server: LocalTransferServer?
    private let worker = DispatchQueue(label: "DualScreenTV.Library", qos: .userInitiated)
    static let appGroup = "group.org.example.DualScreenTV"

    init() {
        GamePreferences.recover()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DSTVRestoreVulkan") {
            GamePreferences.restoreVulkanRenderer()
        }
        if ProcessInfo.processInfo.arguments.contains("-DSTVEnableMetalOptimizations"),
           let data=UserDefaults.standard.data(forKey:GameLibraryDisk.metadataKey),
           let entries=try? PropertyListDecoder().decode([GameEntry].self,from:data) {
            GamePreferences.enableMetalSurfaceCache(for:entries.filter {$0.system == .nintendo3DS}.map(\.id))
        }
        #endif
        busy = true
        worker.async { [weak self] in
            do {
                let directories = try StorageDirectories.prepare()
                let disk = try GameLibraryDisk(root: directories.saves.deletingLastPathComponent())
                let coreHash = try SaveDisk.identity(for: Bundle.main.bundleURL.appendingPathComponent("Frameworks/melondsds_libretro.dylib"))
                let games = try disk.entries()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.directories = directories; self.disk = disk; self.coreHash = coreHash
                    self.games = games; self.busy = false; self.publishShelf()
                }
            } catch {
                print("Storage initialization failed: \(error)")
                Task { @MainActor [weak self] in self?.busy = false; self?.message = error.localizedDescription }
            }
        }
    }
    func reload() { operation { _ = try $0.entries() } }
    func operation(_ work: @escaping @Sendable (GameLibraryDisk) throws -> Void) {
        guard let disk, !busy else { return }
        busy = true
        worker.async { [weak self] in
            let result = Result { try work(disk); return try disk.entries() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let games): self.games = games; self.publishShelf()
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    private func publishShelf() {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) else { return }
        let shared = groupURL.appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
        let items = ShelfGame.snapshot(games)
        guard let disk else { return }
        let placeholder = shelfPlaceholder
        worker.async {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            do {
                try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
                let url = shared.appendingPathComponent("placeholder.png")
                if !FileManager.default.fileExists(atPath: url.path) { try placeholder?.write(to: url, options: .atomic) }
                var snapshot = items
                for index in snapshot.indices {
                    guard let source = disk.artworkURL(snapshot[index].artwork),
                          FileManager.default.fileExists(atPath: source.path) else { snapshot[index].artwork = nil; continue }
                    let target = shared.appendingPathComponent(source.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try Data(contentsOf: source).write(to: target, options: .atomic)
                    }
                }
                try encoder.encode(snapshot).write(to: shared.appendingPathComponent("shelf.plist"), options: .atomic)
                let used = Set(snapshot.compactMap(\.artwork))
                for file in try FileManager.default.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil)
                    where GameArtwork.validFilename(file.lastPathComponent) && !used.contains(file.lastPathComponent) {
                    try? FileManager.default.removeItem(at: file)
                }
                TVTopShelfContentProvider.topShelfContentDidChange()
            } catch { print("Top Shelf snapshot failed: \(error)") }
        }
    }
    private lazy var shelfPlaceholder: Data? = {
        UIGraphicsImageRenderer(size: CGSize(width: 800, height: 450)).image { context in
            UIColor(red: 0.08, green: 0.15, blue: 0.27, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 450))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: UIColor.white]
            ("DualScreenTV" as NSString).draw(at: CGPoint(x: 180, y: 180), withAttributes: attributes)
        }.pngData()
    }()
    func startTransfer() {
        guard server == nil, !stoppingTransfer, !busy, let disk else { return }
        transferStatus = "Starting local transfer…"; transferURLs = []
        let server = LocalTransferServer(library: disk, coreHash: coreHash, pairingCode: transferCode, activity: { [weak self] active in
            Task { @MainActor [weak self] in self?.transferActive = active }
        }, status: { [weak self] status, urls in
            Task { @MainActor [weak self] in self?.transferStatus = status; self?.transferURLs = urls
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-DSTVTransferSmoke") {
                    print("Transfer smoke URLs: " + urls.joined(separator: " "))
                    print("Transfer smoke pairing code: " + (self?.transferCode ?? ""))
                }
                #endif
            }
        }, changed: { [weak self] in Task { @MainActor [weak self] in self?.reload() } })
        self.server = server; server.start()
    }
    func stopTransfer(reload: Bool = true, completion: @escaping @MainActor () -> Void = {}) {
        guard let active = server else { completion(); return }
        server = nil; transferURLs = []; stoppingTransfer = true
        // Drain the network owner, including a restore already finalizing, before
        // another GameSession may read/write save files. Never block the UI thread.
        active.stop { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stoppingTransfer = false
                if reload { self.reload() }
                completion()
            }
        }
    }

}

struct LibraryView: View {
    @StateObject private var library = LibraryStore()
    @StateObject private var companionHost = CompanionHostModel()
    @Environment(\.scenePhase) private var phase
    @State private var session: GameSession?
    @State private var launching = false
    @State private var details: GameEntry?
    @State private var confirmingDelete = false
    @State private var importing = false
    @State private var companion = false
    @State private var controllerPage = false
    @State private var interfaceSettings = false
    @State private var welcome = false
    @AppStorage("onboarding.complete") private var onboarded = false
    @State private var pendingLink: String?
    @State private var didStartTransferSmoke = false
    @State private var didPreviewDetails = false
    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 40)]
    var body: some View {
        NavigationView {
            Group {
            VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(spacing: 14) {
                            Image("BrandSplash").resizable().scaledToFill().frame(width: 300, height: 80).clipped().blendMode(.screen).accessibilityLabel("DualScreenTV")
                            Color.clear.frame(height: 29)
                        }
                        Spacer()
                        VStack(spacing: 14) {
                            Button("Help", systemImage: "questionmark.circle") { welcome = true }.frame(height: 80)
                            Color.clear.frame(height: 29)
                        }
                        VStack(spacing: 14) {
                            Button("Settings", systemImage: "gearshape") { interfaceSettings = true }.frame(height: 80)
                            Color.clear.frame(height: 29)
                        }
                        VStack(spacing: 14) {
                            Button { controllerPage = true } label: { Image(systemName: "gamecontroller").font(.system(size: 28)) }
                                .frame(height: 80).accessibilityLabel("Controller Settings")
                            Text("Controllers").font(.system(size: 17)).foregroundStyle(.secondary).frame(height: 29)
                        }
                        VStack(spacing: 14) {
                            Button("iPad Companion", systemImage: "ipad") { companion = true }
                                .disabled(library.busy || library.stoppingTransfer).frame(height: 80)
                            Text(companionHost.code).font(.system(size: 24, weight: .medium, design: .monospaced)).foregroundColor(.secondary).frame(height: 29)
                        }
                        VStack(spacing: 14) {
                            Button("Add/Edit Games", systemImage: "plus.circle") { importing = true }
                                .disabled(library.disk == nil || library.busy || library.stoppingTransfer).frame(height: 80)
                            Text(library.transferCode).font(.system(size: 24, weight: .medium, design: .monospaced)).foregroundColor(.secondary).frame(height: 29)
                        }
                    }
                    .font(.system(size: 24, weight: .medium))
                    .frame(maxWidth: .infinity)
                    // The header's full width bridges the gap between a left
                    // game card and the trailing Add Games button on Up.
                    .focusSection()
                    .padding(.horizontal, 64).padding(.top, 24).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    VStack(alignment: .leading, spacing: 12) {
                        TVStudioEyebrow(text: "Welcome back")
                        HStack(alignment: .firstTextBaseline) {
                            Text("Your games, ready when you are.").font(.system(size: 48, weight: .semibold, design: .rounded)).tracking(-0.6)
                            Spacer()
                            Text("\(library.games.count) games").font(.system(size: 20, design: .rounded)).foregroundStyle(.gray)
                        }
                    }
                    Divider().overlay(.white.opacity(0.08))
                    if library.games.isEmpty {
                        Text(library.busy ? "Loading your library…" : "No games yet. Choose Add/Edit Games to transfer supported game files from a phone or computer on this network.")
                            .font(.title3).padding(.vertical, 40)
                    } else {
                        let recent = library.games.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! }
                        let favourites = library.games.filter(\.favourite)
                        if !recent.isEmpty { shelf("Recently Played", games: Array(recent.prefix(5))) }
                        if !favourites.isEmpty { shelf("Favourites", games: favourites) }
                        shelf("All Games", games: library.games)
                    }
                    Text("Game files may need re-importing if tvOS reclaims storage. Saves are stored separately. Use Save Backup to keep an off-device copy of valuable progress.")
                        .font(.caption).foregroundColor(.secondary)
                    Text("Choose Details beneath a game to manage or delete it. During a game, press LB + RB + A together for the quick menu.")
                        .font(.caption).foregroundColor(.secondary)
                }.padding(.horizontal, 64).padding(.top, 28).padding(.bottom, 64)
            }
            }
            .background(TVStudioBackground())
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $interfaceSettings) {
            VStack(spacing: 35) {
                Text("Settings").font(.title)
                Button("Apple TV Settings") { interfaceSettings = false; openSystemSettings() }
                Button("Done") { interfaceSettings = false }
            }.padding(60)
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .buttonStyle(TVStudioButtonStyle())
        .disabled(launching)
        .overlay {
            if launching {
                ZStack {
                    Color.black.opacity(0.85).ignoresSafeArea()
                    VStack(spacing: 24) { ProgressView(); Text("Starting game…").font(.title2) }
                }
            }
        }
        .fullScreenCover(item: $session, onDismiss: { library.reload() }) { active in
            GameHostView(session: active) {
                guard active.states?.busy != true else { return }
                active.stop(); session = nil
            }.ignoresSafeArea().interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $controllerPage, onDismiss: { handleLink() }) { ControllerSettingsPage(openSystemSettings: openSystemSettings) { controllerPage = false } }
        .sheet(isPresented: $welcome, onDismiss: { handleLink() }) { WelcomeView { onboarded = true; welcome = false } }
        .sheet(isPresented: $companion, onDismiss: { handleLink() }) { CompanionHostView(model: companionHost) }
        .sheet(isPresented: $importing, onDismiss: { library.reload(); handleLink() }) {
            TransferView(library: library)
        }
        .fullScreenCover(item: $details, onDismiss: { handleLink() }) { game in
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        HStack(alignment: .top, spacing: 40) {
                            LibraryArtwork(url: library.disk?.artworkURL(game.artwork))
                                .frame(width: 360, height: 220).clipShape(RoundedRectangle(cornerRadius: 24))
                            VStack(alignment: .leading, spacing: 16) {
                                Text(game.title.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 42, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                                Text(game.system.title).font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
                                Text(game.availability == .available ? "Ready to play" : "Import this game again to play.").foregroundStyle(.secondary)
                                Text("Your display, graphics and controller choices are remembered for this game.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 24) {
                            Button("Play", systemImage: "play.fill") { pendingLink = game.id; details = nil }.disabled(game.availability != .available)
                            Button(game.favourite ? "Remove Favourite" : "Add Favourite", systemImage: "heart") {
                                details = nil; library.operation { disk in try disk.update(game.id) { $0.favourite.toggle() } }
                            }
                            Button("Done") { details = nil }
                        }.focusSection()
                        Divider()
                        Text("Saved progress").font(.system(size: 30, weight: .semibold, design: .rounded))
                        if let disk = library.disk, let saves = library.directories?.saves {
                            HStack(spacing: 24) {
                                NavigationLink("Browse Save Files") {
                                    NativeSaveBrowserView(game: game, disk: disk, coreHash: library.coreHash, transferURL: library.transferQRURL)
                                }
                                NavigationLink("Backup History") { GameBackupView(game: game, saves: saves) }
                            }.focusSection()
                        }
                        Text("Browse folders and sort saves, or recover an earlier backup. Use Export to download a file to your phone or computer.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Manage this game").font(.system(size: 30, weight: .semibold, design: .rounded))
                        HStack(spacing: 24) {
                            Button("Reset Game Settings") { GamePreferences.reset(game.id); details = nil }
                            if game.artwork != nil {
                                Button("Remove Picture") { details = nil; library.operation { try $0.removeArtwork(game.id) } }
                            }
                        }.focusSection()
                        HStack(spacing: 24) {
                            Button("Remove Local Game File", role: .destructive) {
                                details = nil; library.operation { try $0.removeROM(game.id) }
                            }.disabled(game.availability != .available)
                            Button("Delete Game from Library", role: .destructive) { confirmingDelete = true }
                        }.focusSection()
                        Text("Both removal options keep saves and save states. Removing only the file also keeps its shelf entry.").font(.caption).foregroundStyle(.secondary)
                    }.padding(64).frame(maxWidth: 1600).frame(maxWidth: .infinity, alignment: .top)
                }
                .background(TVStudioBackground()).navigationBarHidden(true)
                .buttonStyle(TVStudioButtonStyle())
                .alert("Delete \(game.title)?", isPresented: $confirmingDelete) {
                    Button("Delete Game", role: .destructive) {
                        pendingLink = nil; details = nil; library.operation { try $0.deleteGame(game.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("The game file and shelf entry will be removed. Saves and states will be kept.") }
            }.navigationViewStyle(.stack)
        }
        .alert("DualScreenTV", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK") { library.message = nil }
        } message: { Text(library.message ?? "") }
        .onOpenURL { url in
            // Invalid links also return to the library rather than leaving an
            // unrelated game running behind an inaccessible error alert.
            pendingLink = GameIdentity.deepLink(url) ?? ""
            if let active = session {
                guard active.states?.busy != true else {
                    pendingLink = nil; library.message = "Finish the current save operation, then select the game again."; return
                }
                active.stop(); session = nil
            } else if companion { companion = false }
            else if importing {
                library.stopTransfer(); importing = false
            } else if details != nil { details = nil }
            else { handleLink() }
        }
        .onChange(of: library.busy) { busy in
            if !busy {
                handleLink()
                startHomeTransfers()
                #if DEBUG
                if !didStartTransferSmoke && ProcessInfo.processInfo.arguments.contains("-DSTVTransferSmoke") {
                    didStartTransferSmoke = true; importing = true
                }
                if !didStartTransferSmoke && ProcessInfo.processInfo.arguments.contains("-DSTVCompanionSmoke") {
                    didStartTransferSmoke = true; companion = true
                }
                #endif
            }
        }
        // Fast disk loads can coalesce busy=true/false into one UI update.
        // A newly populated library must also retry a queued shelf/deep link.
        .onChange(of: library.games) { _ in previewDetails(); handleLink(); startHomeTransfers() }
        .onChange(of: library.stoppingTransfer) { stopping in
            if !stopping {
                handleLink()
                startHomeTransfers()
            }
        }
        .onAppear { companionHost.start(); startHomeTransfers(); if !onboarded && pendingLink == nil { welcome = true } }
        .onChange(of: library.transferActive) { _ in updateIdleTimer() }
        .onChange(of: importing) { _ in updateIdleTimer() }
        .onChange(of: session?.id) { _ in updateIdleTimer() }
        .onChange(of: details?.id) { _ in updateIdleTimer() }
        .onChange(of: companion) { _ in updateIdleTimer() }
        .onChange(of: controllerPage) { _ in updateIdleTimer() }
        .onChange(of: welcome) { _ in updateIdleTimer() }
        .onChange(of: launching) { _ in updateIdleTimer() }
        .onChange(of: phase) { phase in
            companionHost.sceneActive(phase == .active)
            if phase != .active { library.stopTransfer(); UIApplication.shared.isIdleTimerDisabled = false }
            else if session == nil { library.reload(); startHomeTransfers() }
            updateIdleTimer()
        }
    }
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in
            if !(await UIApplication.shared.open(url)) { library.message = "Open Apple TV Settings → Apps → DualScreenTV." }
        }
    }
    private func previewDetails() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if !didPreviewDetails && arguments.contains("-DSTVPreviewControllers") { didPreviewDetails = true; controllerPage = true; return }
        guard !didPreviewDetails, let index = arguments.firstIndex(of: "-DSTVPreviewDetails"), index + 1 < arguments.count,
              let game = library.games.first(where: { $0.id == arguments[index + 1] }) else { return }
        didPreviewDetails = true; details = game
        #endif
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = phase == .active &&
            (session != nil || launching || importing || library.transferActive || details != nil || companion || welcome || controllerPage)
        #if DEBUG
        print("TV idle prevention: \(UIApplication.shared.isIdleTimerDisabled), game active: \(session != nil)")
        #endif
    }
    @ViewBuilder private func shelf(_ title: String, games: [GameEntry]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 32, weight: .semibold)).tracking(-0.5)
            Spacer()
            TVStudioEyebrow(text: "\(games.count) in this collection")
        }
        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(games) { game in
                VStack(alignment: .leading, spacing: 14) {
                    Button { if game.availability == .available { launch(game) } else { details = game } } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            LibraryArtwork(url: library.disk?.artworkURL(game.artwork)).frame(height: 220)
                            LibraryScrollingTitle(title: game.title).frame(height: 56)
                            HStack {
                                Text(game.system.title).font(.system(size: 20, weight: .medium)).foregroundStyle(.gray)
                                Spacer(minLength: 8)
                                Image(systemName: game.availability == .available ? "play.circle" : "arrow.down.circle")
                                    .font(.system(size: 24)).foregroundStyle(.gray)
                            }.lineLimit(1)
                            Text(game.availability == .available ? "Ready to play" : "Needs re-import")
                                .font(.system(size: 17, design: .rounded)).foregroundStyle(.gray)
                        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 356, alignment: .topLeading)
                    }.buttonStyle(TVStudioButtonStyle(card: true))
                    .disabled(library.busy || library.stoppingTransfer)
                    Button("Details", systemImage: "ellipsis.circle") { details = game }.font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Make Down from the trailing header reach even a short/one-card shelf.
        .focusSection()
    }
    private func startHomeTransfers() {
        guard phase == .active, session == nil, !launching, pendingLink == nil else { return }
        library.startTransfer()
    }
    private func handleLink() {
        guard !launching, phase == .active, !library.busy, !library.stoppingTransfer, session == nil, !importing, !companion, details == nil, !welcome, !controllerPage, let id = pendingLink else { return }
        pendingLink = nil
        guard GameIdentity.valid(id) else { library.message = "This game link is invalid. Choose a game from your library."; return }
        guard let game = library.games.first(where: { $0.id == id }) else { library.message = "This game is no longer in your library. Import it to play."; return }
        if game.availability == .needsImport { details = game }
        else { launch(game) }
    }
    private func launch(_ game: GameEntry) {
        guard !launching, session == nil, !library.busy, !library.stoppingTransfer, !importing, let disk = library.disk,
              let directories = library.directories else { return }
        launching = true
        Task { @MainActor in
            defer { launching = false; handleLink(); startHomeTransfers() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                library.stopTransfer(reload: false) { continuation.resume() }
            }
            guard phase == .active else { return }
            do {
                let active = try await GameSession(game: game, rom: disk.romURL(game.id), directories: directories, coreHash: library.coreHash, companion: companionHost)
                // A newer link queued during boot is handled only after this owner stops.
                if pendingLink != nil { active.stop(); return }
                session = active
                let sram = dstv_sram_size(), state = dstv_state_size()
                let defaultDS = game.system == .nintendoDS && dstv_is_dust() == 0 && dstv_is_desmume() == 0
                library.operation { disk in try disk.update(game.id) {
                    $0.lastPlayed = Date()
                    // Native-save cores must not invalidate melonDS checkpoint metadata.
                    if defaultDS {
                        if sram > 0 { $0.sramSize = sram }
                        if state > 0 { $0.stateSize = state }
                    }
                } }
            } catch {
                GamePreferences.end()
                print("Game launch failed (\(game.system.title)): \(error.localizedDescription)")
                library.message = error.localizedDescription; library.reload()
            }
        }
    }
}

struct TransferView: View {
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private var qr: CGImage? {
        guard let value = library.transferQRURL else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), from: image.extent.applying(CGAffineTransform(scaleX: 6, y: 6)))
    }
    var body: some View {
        HStack(spacing: 60) {
            VStack(alignment: .leading, spacing: 28) {
                TVStudioEyebrow(text: "Your library. Your progress.")
                Text("Add/Edit Games").font(.system(size: 52, weight: .bold)).tracking(-1)
                Text(library.transferStatus)
                Text("On a phone or computer connected to this network, scan the code or open:")
                ForEach(Array(library.transferURLs.enumerated()), id: \.offset) { index, url in
                    Text((index == 0 ? "" : "Fallback: ") + url).font(.system(size: 23, design: .monospaced))
                }
                if !library.transferURLs.isEmpty {
                    Text("Bookmark the address above to reuse it next time. Then enter this connection code:").font(.headline)
                    Text(library.transferCode).font(.system(size: 48, weight: .semibold, design: .monospaced))
                    Text("Scanning the QR code connects directly.").font(.caption)
                }
                Text("Pair from the home screen or this page. Transfers stay available until you launch a game or leave the app. Keep this code private.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Done") { dismiss() }
            }.tvStudioPanel()
            if let qr { Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 340, height: 340).padding(24).background(.white) }
        }.padding(70)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVStudioBackground())
        .buttonStyle(TVStudioButtonStyle())
        .onAppear { library.startTransfer() }
    }
}

// Only visible cards decode thumbnails, away from UI/emulation work.
struct LibraryArtwork: View {
    let url: URL?
    @State private var image: CGImage?
    var body: some View {
        Color(white: 0.12)
        .overlay {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "gamecontroller.fill").font(.system(size: 60)).foregroundColor(.white) }
        }
        .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await Task.detached(priority: .utility) { GameArtwork.load(url) }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

// Reserve a single title row; long names move only while their game is focused.
private struct LibraryScrollingTitle: View {
    let title: String
    @Environment(\.isFocused) private var focused
    @State private var textWidth: CGFloat = 0
    @State private var started: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}")))
    }
    var body: some View {
        GeometryReader { bounds in
            let overflow = max(0, textWidth - bounds.size.width)
            TimelineView(.animation(paused: !focused || reduceMotion || overflow <= 0)) { timeline in
                Text(cleanTitle).font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { text in
                        Color.clear.onAppear { textWidth = text.size.width }
                            .onChange(of: text.size.width) { textWidth = $0; started = focused ? Date() : nil }
                    })
                    .offset(x: offset(at: timeline.date, overflow: overflow))
                    .transaction { $0.animation = nil }
            }
            .onAppear { started = focused ? Date() : nil }
            .onChange(of: focused) { started = $0 ? Date() : nil }
            .onChange(of: title) { _ in started = focused ? Date() : nil }
            .onDisappear { started = nil }
        }.clipped().accessibilityLabel(cleanTitle)
    }
    private func offset(at date: Date, overflow: CGFloat) -> CGFloat {
        guard focused, !reduceMotion, overflow > 0, let started else { return 0 }
        let travel = max(2, Double(overflow / 45)), pause = 1.2
        let time = max(0, date.timeIntervalSince(started)).truncatingRemainder(dividingBy: 2 * (travel + pause))
        if time < pause { return 0 }
        if time < pause + travel { return -overflow * CGFloat((time - pause) / travel) }
        if time < 2 * pause + travel { return -overflow }
        return -overflow * CGFloat(1 - (time - 2 * pause - travel) / travel)
    }
}
