import SwiftUI
import UIKit
import MediaPlayer
import GameController

struct GameHostView: UIViewControllerRepresentable {
    @StateObject private var input = ControllerInput()
    let session: GameSession
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> RemoteGameHostController {
        RemoteGameHostController(input: input, session: session, onExit: onExit)
    }
    func updateUIViewController(_ controller: RemoteGameHostController, context: Context) {}
}

// Keep the existing SwiftUI game view. UIKit handles remote presses that some
// third-party remotes deliver outside the GameController micro profile.
@MainActor
final class RemoteGameHostController: UIHostingController<ContentView>, UIGestureRecognizerDelegate {
    private let input: ControllerInput
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var acceptingCommands = false
    private var menuFromGamepad = false
    private var playPauseFromGamepad = false

    private let session: GameSession
    private let onExit: () -> Void

    init(input: ControllerInput, session: GameSession, onExit: @escaping () -> Void) {
        self.input = input
        self.session = session
        self.onExit = onExit
        super.init(rootView: ContentView(controller: input, settings: input.settings, session: session, onExit: onExit))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A tap recognizer is more reliable for Back/Menu than polling its
        // brief gamepad state, and consumes the app's default Back action.
        for (type, action) in [(UIPress.PressType.menu, #selector(menuPressed)),
                               (.playPause, #selector(playPausePressed))] {
            let gesture = UITapGestureRecognizer(target: self, action: action)
            gesture.delegate = self
            gesture.allowedPressTypes = [NSNumber(value: type.rawValue)]
            view.addGestureRecognizer(gesture)
        }
        let center = NotificationCenter.default
        let activate: @MainActor @Sendable () -> Void = { [weak self] in self?.enableCommands() }
        let deactivate: @MainActor @Sendable () -> Void = { [weak self] in self?.disableCommands() }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { activate() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { deactivate() }
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UIApplication.shared.applicationState == .active { enableCommands() }
    }

    // A long Menu/Back press can fail the tap recognizer and otherwise bubble
    // to tvOS on release. Consume every phase, while GameController continues
    // to supply held game buttons and the tap recognizer supplies remote taps.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = Set(presses.filter { $0.type != .menu })
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = Set(presses.filter { $0.type != .menu })
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = Set(presses.filter { $0.type != .menu })
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        disableCommands()
        input.releaseControllers()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        // tvOS maps extended-gamepad X to Play/Pause and B/Menu to Back.
        // Always accept these gestures so UIKit consumes the system action.
        // Rejecting a gamepad's Menu event lets Back escape to navigation.
        // Capture its source at press-begin, before the button is released,
        // and suppress only the extra remote binding in the action below.
        let pads = GCController.controllers().compactMap(\.extendedGamepad)
        switch press.type {
        case .playPause: playPauseFromGamepad = pads.contains { $0.buttonX.isPressed }
        case .menu: menuFromGamepad = pads.contains { $0.buttonB.isPressed || $0.buttonMenu.isPressed || ($0.buttonOptions?.isPressed ?? false) }
        default: break
        }
        return true
    }

    @objc private func menuPressed() {
        guard !menuFromGamepad else { return }
        if input.quickMenuVisible { input.quickMenuVisible = false } else { input.pressRemote(.menu) }
    }
    @objc private func playPausePressed() {
        guard !playPauseFromGamepad else { return }
        if !input.quickMenuVisible { input.pressRemote(.playPause) }
    }

    private func bind(_ command: MPRemoteCommand, to button: RemoteButton) {
        command.isEnabled = true
        let deliver: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.acceptingCommands, !self.input.quickMenuVisible else { return }
            self.input.pressRemote(button)
        }
        let target = command.addTarget { @Sendable event in
            // A seek's end is not a second button press. Media commands don't
            // consistently provide raw key-up, so translate them into taps.
            if let seek = event as? MPSeekCommandEvent, seek.type == .endSeeking { return .success }
            Task { @MainActor in deliver() }
            return .success
        }
        commandTargets.append((command, target))
    }

    private func enableCommands() {
        guard !acceptingCommands else { return }
        input.settings.reload()
        // Merely registering MPRemoteCommandCenter targets can move HomePod
        // audio onto the two-second buffered route. Do not initialize either
        // media singleton at all unless compatibility is explicitly enabled.
        // Leave Now Playing and transport controls with the music app when mixing.
        guard input.settings.values.mediaButtonsEnabled,
              !input.settings.values.mixWithOtherAudio else { return }
        acceptingCommands = true
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
            bind(command, to: .playPause)
        }
        for command in [center.seekBackwardCommand, center.skipBackwardCommand, center.previousTrackCommand] {
            bind(command, to: .rewind)
        }
        for command in [center.seekForwardCommand, center.skipForwardCommand, center.nextTrackCommand] {
            bind(command, to: .fastForward)
        }
        // Some directional remotes send a rate-change for a short FF/RW press
        // and seek begin/end for a hold (Apple's directional remote guidance).
        let rate = center.changePlaybackRateCommand
        rate.supportedPlaybackRates = [-96, -48, -24, -8, 1, 8, 24, 48, 96]
        rate.isEnabled = true
        let deliverRate: @MainActor @Sendable (Float) -> Void = { [weak self] value in
            guard let self, self.acceptingCommands, !self.input.quickMenuVisible else { return }
            self.input.pressRemote(value < 0 ? .rewind : .fastForward)
        }
        let target = rate.addTarget { @Sendable event in
            guard let change = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let value = change.playbackRate
            guard value != 1 && value != 0 else { return .success }
            Task { @MainActor in deliverRate(value) }
            return .success
        }
        commandTargets.append((rate, target))
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "DualScreenTV",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    private func disableCommands() {
        acceptingCommands = false
        let hadMediaCommands = !commandTargets.isEmpty
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
        if hadMediaCommands { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        input.clear()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in commandTargets { command.removeTarget(target) }
    }
}
