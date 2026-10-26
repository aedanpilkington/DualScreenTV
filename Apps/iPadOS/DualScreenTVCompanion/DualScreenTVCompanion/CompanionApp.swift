import SwiftUI
import UIKit
import Combine
import CoreGraphics

@main struct CompanionApp: App {
    @StateObject private var backups = AutomaticBackupModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            TabView {
                TransferStudioView().tabItem { Label("Games & Backups", systemImage: "square.stack.3d.up") }
                CompanionView().tabItem { Label("Game Screen", systemImage: "ipad") }
                AutomaticBackupsView(model: backups).tabItem { Label("Save Backups", systemImage: "externaldrive.badge.checkmark") }
            }.tint(.white).preferredColorScheme(.dark)
            .onAppear {
                #if targetEnvironment(macCatalyst)
                backups.activate(true)
                #else
                backups.activate(phase == .active)
                #endif
            }
            .onChange(of: phase) { phase in
                #if !targetEnvironment(macCatalyst)
                backups.activate(phase == .active)
                #endif
            }
        }
    }
}
@MainActor final class CompanionModel: ObservableObject {
    @Published var lastTV = UserDefaults.standard.string(forKey: "companion.lastTV") ?? ""
    @Published var canReconnect = false
    func connect(_ device: LinkDevice, code: String) {
        lastTV = device.name
        UserDefaults.standard.set(device.name, forKey: "companion.lastTV")
        canReconnect = true
        client.connect(device, code: code)
    }
    @Published var devices: [LinkDevice] = []
    @Published var message = "Looking for Apple TVs…"
    @Published var connected = false
    @Published var gameMenu = LinkMenuState()
    @Published var fps = 0
    @Published var replaced = 0
    private var heldButtons: UInt16 = 0
    func button(_ bit: Int, pressed: Bool) {
        let mask = UInt16(1) << bit
        if pressed { heldButtons |= mask } else { heldButtons &= ~mask }
        client.buttons(heldButtons)
    }
    func releaseButtons() { heldButtons = 0; client.buttons(0); client.analog(x: 0, y: 0) }
    lazy var client = LinkClient(devices: { [weak self] devices in
        Task { @MainActor [weak self] in self?.devices = devices }
    }, status: { [weak self] message, connected in
        Task { @MainActor [weak self] in self?.message = message; self?.connected = connected
            if !connected { self?.heldButtons = 0 } }
    }, menu: { [weak self] state in
        Task { @MainActor [weak self] in self?.gameMenu = state }
    })
    func start() {
        #if DEBUG
        // Local simulator layout check; never enabled by saved preferences.
        if ProcessInfo.processInfo.arguments.contains("-DSTVCompanionPreview") {
            connected = true; message = "Display preview"
            let pixels = LinkTestImage.make(sequence: 128, touch: LinkTouchState())
            if let provider = CGDataProvider(data: pixels as CFData),
               let image = CGImage(width: 256, height: 192, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                client.frames.put(LinkFrame(image: image, sequence: 1, timestamp: 0))
            }
            return
        }
        #endif
        client.browse()
    }
    func stop() { releaseButtons(); client.stop() }
}
struct CompanionView: View {
    @StateObject private var model = CompanionModel()
    @State private var code = ""
    @State private var showingSettings = false
    @State private var confirmReturnToLibrary = false
    @State private var stateSlot = 1
    @State private var confirmLoadState = false
    @AppStorage("companion.displayMode") private var modeName = LinkDisplayMode.original.rawValue
    @AppStorage("companion.overscanZoom") private var zoom = 1.08
    @AppStorage("companion.fullscreen") private var fullscreen = false
    @AppStorage("companion.circlePad") private var circlePad = false
    @AppStorage("companion.touchControls") private var touchControls = false
    private var mode: LinkDisplayMode { LinkDisplayMode(rawValue: modeName) ?? .original }
    @Environment(\.scenePhase) private var phase
    private let statsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var previousCount = 0
    @State private var gameScreenVisible = false
    private func updateIdleTimer() {
        #if !targetEnvironment(macCatalyst)
        UIApplication.shared.isIdleTimerDisabled = gameScreenVisible && model.connected && phase == .active
        #endif
    }
    var body: some View {
        NavigationStack {
            Group {
                if model.connected {
                    ZStack(alignment: .topTrailing) {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 12) {
                            if !fullscreen {
                                Text(model.message).font(.headline).foregroundStyle(.white)
                            }
                            if touchControls {
                                DSSkin(circlePad: circlePad, analog: { model.client.analog(x: $0, y: $1) }) {
                                    FrameSurface(mailbox: model.client.frames, touch: { model.client.touch($0) }, mode: mode, zoom: zoom)
                                } button: { model.button($0, pressed: $1) }
                            } else {
                                FrameSurface(mailbox: model.client.frames, touch: { model.client.touch($0) }, mode: mode, zoom: zoom)
                            }
                            if !fullscreen {
                                Text("\(model.fps) received FPS").font(.caption.monospacedDigit()).foregroundStyle(.gray)
                                Button("Fullscreen") { fullscreen = true }.buttonStyle(.borderedProminent)
                            }
                        }.padding(fullscreen ? 0 : 16)
                        Button { model.releaseButtons(); model.client.menu(LinkMenuCommand(.pause)); showingSettings = true } label: {
                            Image(systemName: "gearshape.fill").font(.title2).padding(16)
                                .background(.ultraThinMaterial, in: Circle())
                        }.accessibilityLabel("Display and controller settings").padding(20)
                    }
                    .ignoresSafeArea(edges: fullscreen ? .all : [])
                } else {
                    StudioPage(eyebrow: "Two screens. One adventure.", title: "Your game,\na little closer.", subtitle: "Give your game a second screen, with responsive touch or mouse input and optional on-screen controls.") {
                        Text("Connect your game screen").font(.system(.callout, design: .rounded)).foregroundStyle(.gray)
                        Text("Pick up where you play.").font(.title.bold())
                        Text("Enter the iPad Companion code shown on the Apple TV home screen, then choose your TV. Both devices must be on the same network.").foregroundStyle(.secondary)
                        Text("Companion code").font(.system(.callout, design: .rounded)).foregroundStyle(.gray)
                        TextField("000000", text: $code).keyboardType(.numberPad)
                            .font(.system(size: 36, weight: .medium, design: .monospaced)).tracking(8).multilineTextAlignment(.center)
                            .padding(20).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
                            .onChange(of: code) { value in code = String(value.filter(\.isNumber).prefix(6)) }
                        if model.canReconnect {
                            Button("Reconnect to \(model.lastTV)") { model.client.reconnect() }.buttonStyle(StudioButtonStyle(prominent: true))
                        } else if !model.lastTV.isEmpty {
                            Text("Last connected: \(model.lastTV). Enter the current TV code to pair again.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.devices) { device in
                            Button { model.connect(device, code: code) } label: {
                                Label("Connect to \(device.name)", systemImage: "appletv")
                            }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(code.count != 6).opacity(code.count == 6 ? 1 : 0.45)
                        }
                        Text(model.message).font(.callout).foregroundStyle(.secondary)
                        if model.devices.isEmpty { Text("Allow Local Network access when prompted.").foregroundStyle(.secondary) }
                        Button("Search again") { model.stop(); model.start() }.buttonStyle(StudioButtonStyle())
                    }
                }
            }
            .navigationTitle(model.connected ? "Game Screen" : "")
            .toolbar(model.connected && fullscreen ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(model.connected && fullscreen)
            .toolbar(model.connected && fullscreen ? .hidden : .visible, for: .tabBar)
            .sheet(isPresented: $showingSettings, onDismiss: {
                model.releaseButtons(); model.client.menu(LinkMenuCommand(.resume))
            }) {
                NavigationStack {
                    Form {
                        Section("Game on Apple TV") {
                            if model.gameMenu.active {
                                Button("Resume Game") {
                                    model.releaseButtons(); model.client.menu(LinkMenuCommand(.resume)); showingSettings = false
                                }
                                if model.gameMenu.dualScreen {
                                    Button(model.gameMenu.bottomOnTV ? "Swap Screens (Top on TV)" : "Swap Screens (Bottom on TV)") {
                                        model.releaseButtons(); model.client.menu(LinkMenuCommand(.swapScreens))
                                    }
                                }
                                HStack {
                                    Text("Game Volume")
                                    Slider(value: Binding(get: { Double(model.gameMenu.volume) }, set: { value in
                                        let volume = UInt8(value.rounded())
                                        model.gameMenu.volume = volume
                                        model.client.menu(LinkMenuCommand(.volume, value: volume))
                                    }), in: 0...100, step: 10)
                                    Text("\(model.gameMenu.volume)%").monospacedDigit().frame(width: 50)
                                }
                                Picker("Save State Slot", selection: $stateSlot) {
                                    ForEach(1...10, id: \.self) { Text("Slot \($0)").tag($0) }
                                }
                                Button("Save State") { model.client.menu(LinkMenuCommand(.saveState, value: UInt8(stateSlot))) }
                                Button("Load State") { confirmLoadState = true }
                                Text("Save state availability depends on the core. The result appears on your TV. Use your game's own saves too.").font(.caption).foregroundStyle(.secondary)
                                Button("Open Apple TV App Settings") { model.client.menu(LinkMenuCommand(.openSettings)) }
                                Text("Settings opens on the TV. Use your TV remote there; your game stays paused. Game Volume does not change your music volume.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Return to Library", role: .destructive) { confirmReturnToLibrary = true }
                            } else {
                                Text("Open a game on Apple TV to use these controls.").foregroundStyle(.secondary)
                            }
                        }
                        Section("Bottom Screen") {
                            Toggle("Fullscreen", isOn: $fullscreen)
                            Picker("Display", selection: $modeName) {
                                ForEach(LinkDisplayMode.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                            }
                            if mode == .overscan {
                                Slider(value: $zoom, in: 1...1.3, step: 0.01) { Text("Overscan") }
                                Text("Zoom: \(Int((zoom * 100).rounded()))%")
                            }
                            Text("Original preserves 4:3. Overscan zooms slightly. Fill crops to fill. Stretch fills by changing proportions.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Section("Touch Controls") {
                            Toggle("On-screen controls", isOn: $touchControls)
                            Toggle("Circle Pad instead of D-pad", isOn: $circlePad)
                                .disabled(!touchControls)
                            Text("Adds A/B/X/Y, L/R, Start and Select. Use D-pad for DS games or Circle Pad for analogue movement in 3DS games. A TV gamepad remains available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Section {
                            Button("Disconnect", role: .destructive) { model.releaseButtons(); model.client.disconnect(); showingSettings = false }
                        }
                    }
            .confirmationDialog("Return to the Apple TV library? Unsaved progress will be lost.", isPresented: $confirmReturnToLibrary, titleVisibility: .visible) {
                Button("Return to Library", role: .destructive) {
                    model.releaseButtons(); model.client.menu(LinkMenuCommand(.returnToLibrary)); showingSettings = false
                }
            }
                    .alert("Load this save state?", isPresented: $confirmLoadState) {
                        Button("Load") { model.client.menu(LinkMenuCommand(.loadState, value: UInt8(stateSlot))) }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("This replaces the current running game with the selected slot.") }
                    .textCase(nil)
                    .scrollContentBackground(.hidden)
                    .background(Color(red: 0.045, green: 0.043, blue: 0.041))
                    .navigationTitle("Companion Settings")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.client.menu(LinkMenuCommand(.resume)); showingSettings = false } } }
                }
            }
            .onChange(of: circlePad) { _ in model.releaseButtons() }
            .onChange(of: touchControls) { _ in model.releaseButtons() }
            .onChange(of: fullscreen) { _ in model.releaseButtons() }
        }
        .onAppear { gameScreenVisible = true; model.start(); updateIdleTimer() }
        .onDisappear { gameScreenVisible = false; updateIdleTimer(); model.stop() }
        .onChange(of: model.connected) { _ in updateIdleTimer() }
        .onChange(of: phase) { phase in
            if phase == .active && gameScreenVisible { model.start() } else { model.stop() }
            updateIdleTimer()
        }
        .onReceive(statsTimer) { _ in
            let counts = model.client.frames.counts
            model.fps = max(0, counts.received - previousCount); previousCount = counts.received
            model.replaced = counts.replaced
        }
    }
}
