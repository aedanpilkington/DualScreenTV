import SwiftUI
import Combine

@MainActor final class CompanionHostModel: ObservableObject {
    @Published var status = LinkHostStatus()
    private lazy var host = LinkHost { [weak self] status in Task { @MainActor [weak self] in self?.status = status } }
    var code: String { host.pairingCode }
    private var enabled = false
    var connected: Bool { host.wantsGameFrames }
    var latestAnalog: (x: Int16, y: Int16) { host.latestAnalog }
    var latestButtons: UInt16 { host.latestButtons }
    // The stylus belongs to the emulated bottom screen, wherever it is shown.
    private var touchNeedsRelease = false
    var tvScreen: DSScreen = .top {
        didSet { if oldValue != tvScreen { touchNeedsRelease = true } }
    }
    var latestTouch: LinkTouchState {
        let touch = host.latestTouch
        if !touch.pressed { touchNeedsRelease = false }
        return tvScreen == .top && !touchNeedsRelease ? touch : LinkTouchState()
    }
    func publishGameFrame() {
        guard host.wantsGameFrames else { return }
        var pixels = Data(count: LinkPacket.frameBytes)
        let copied = pixels.withUnsafeMutableBytes { dstv_video_copy_screen_rgba(tvScreen == .top ? 1 : 0, $0.baseAddress, $0.count) }
        if copied == 1 { host.publishGameFrame(pixels) }
    }
    func takeMenuCommands() -> [LinkMenuCommand] { host.takeMenuCommands() }
    func publishMenu(_ state: LinkMenuState) { host.publishMenu(state) }
    func endGame() { host.endGame(); host.publishMenu(LinkMenuState()) }
    func sceneActive(_ active: Bool) {
        if active { if enabled { host.start() } } else { host.stop() }
    }
    func start() {
        enabled = true
        host.start()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DSTVMenuSmoke") || ProcessInfo.processInfo.arguments.contains("-DSTVCompanionSmoke") || ProcessInfo.processInfo.arguments.contains("-DSTV3DSSmoke") { print("Companion smoke pairing code: " + code) }
        #endif
    }
    func stop() { enabled = false; host.stop(); status.message = "Companion service stopped" }
}
struct CompanionHostView: View {
    @ObservedObject var model: CompanionHostModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 24) {
            TVStudioEyebrow(text: "Two screens. One adventure.")
            Text("Companion").font(.system(size: 52, weight: .bold)).tracking(-1)
            Text("Open DualScreenTV Companion on your iPad or Mac on this network. Select this Apple TV and enter:")
                .multilineTextAlignment(.center)
            Text(model.code).font(.system(size: 64, weight: .semibold, design: .monospaced))
            Text(model.status.message).font(.title2)
            Label(model.connected ? "Ready to play" : "Waiting for your companion", systemImage: model.connected ? "checkmark.circle" : "wifi")
                .font(.system(size: 20, design: .monospaced)).foregroundStyle(.gray)
            Text("Launch a game to stream the screen opposite the TV. Touch works while the bottom screen is on the iPad. The animation is a connection preview.")
                .font(.caption).foregroundColor(.secondary)
            Text("Keep the pairing code private. One companion can connect. The connection stays active when you close this page.")
                .font(.caption).foregroundColor(.secondary)
            Button("Done") { dismiss() }
            Button("Stop Companion") { model.stop(); dismiss() }
        }.frame(maxWidth: 1100).tvStudioPanel().padding(70)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVStudioBackground())
        .buttonStyle(TVStudioButtonStyle())
        .onAppear { model.start() }
    }
}
