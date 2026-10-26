import Combine
import GameController

@MainActor
final class ControllerInput: ObservableObject {
    private var selected: GCController?
    private var remote: GCController?
    let settings = AppSettings()
    private var pulses = RemoteButtonPulses()
    private var usesShapeLabels = false
    private var movementStick = StickDirections()
    private var gamepadChord = ScreenShortcutLatch<GamepadButton>()
    private var quickMenuChord = ScreenShortcutLatch<GamepadButton>()
    @Published var quickMenuVisible = false
    private var remoteChord = ScreenShortcutLatch<RemoteButton>()
    private(set) var screenSwitchPressed = false
    private var actions: UInt8 = 0
    private var previousActions: UInt8 = 0
    private(set) var actionEdges: UInt8 = 0
    var fastForwardHeld: Bool { actions & 1 != 0 }

    private func include(_ binding: InputBinding, in buttons: inout UInt16) {
        buttons |= binding.mask
        actions |= binding.actionMask
    }

    // Poll on the emulation thread. capture() provides a consistent snapshot;
    // no controller event handler writes into the core from a background queue.
    func poll() {
        screenSwitchPressed = false
        previousActions = actions
        actions = 0
        defer { actionEdges = actions & ~previousActions }
        dstv_set_analog(0, 0, 0, 0)
        let connected = GCController.controllers()
        if selected == nil || !connected.contains(where: { $0 === selected }) {
            gamepadChord.clear()
            quickMenuChord.clear()
            movementStick.clear()
            selected = connected.first { $0.extendedGamepad != nil }
            if let pad = selected?.extendedGamepad {
                // Apple maps the west button to X and north to Y. The requested
                // DS mapping uses Triangle for X and Square for Y when labeled
                // with shapes. Inspect framework symbols, never vendor names.
                usesShapeLabels = pad.buttonY.sfSymbolsName?.contains("triangle") == true
                pad.buttonX.preferredSystemGestureState = .disabled
                pad.buttonB.preferredSystemGestureState = .disabled
                pad.buttonMenu.preferredSystemGestureState = .disabled
                pad.buttonOptions?.preferredSystemGestureState = .disabled
                #if DEBUG
                print("Controller: \(selected?.vendorName ?? "Extended gamepad")")
                #endif
            }
        }
        // Keep the remote usable even while an Xbox/PS controller is connected.
        let nextRemote = connected.contains(where: { $0 === remote }) ? remote :
            connected.first { $0.extendedGamepad == nil && $0.microGamepad != nil }
        if remote !== nextRemote {
            remote?.microGamepad?.buttonMenu.pressedChangedHandler = nil
            pulses.clear()
            remoteChord.clear()
            remote = nextRemote
            remote?.handlerQueue = .main
            if let pad = remote?.microGamepad {
                pad.reportsAbsoluteDpadValues = true
                pad.allowsRotation = false
                pad.buttonMenu.preferredSystemGestureState = .disabled
                // SDK guidance: Menu events can be shorter than a frame.
                pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    MainActor.assumeIsolated { self?.pressRemote(.menu) }
                }
                #if DEBUG
                print("Controller: Siri Remote / micro gamepad")
                #endif
            }
        }
        let remotePad = remote?.capture().microGamepad
        var buttons = remoteDirections(remotePad)
        var remotePressed = pulses.nextButtons()
        if let pad = remotePad {
            let center = pad.buttons[GCInputDirectionalCenterButton]
            if center?.isPressed ?? pad.buttonA.isPressed { remotePressed.insert(.center) }
            if pad.buttonX.isPressed { remotePressed.insert(.playPause) }
        }
        let remoteResult = remoteChord.update(pressed: remotePressed,
            pair: settings.values.remoteScreenShortcut ? [.center, .playPause] : [])
        screenSwitchPressed = remoteResult.switched
        for button in remotePressed.subtracting(remoteResult.consumed) {
            include(settings.values.mapping(for: button), in: &buttons)
        }
        let snapshot = selected?.capture()
        guard let pad = snapshot?.extendedGamepad else {
            dstv_set_buttons(buttons)
            return
        }
        let inputs: [(GamepadButton, Bool)] = [
            (.south, pad.buttonA.isPressed), (.east, pad.buttonB.isPressed),
            (.west, pad.buttonX.isPressed), (.north, pad.buttonY.isPressed),
            (.leftShoulder, pad.leftShoulder.isPressed), (.rightShoulder, pad.rightShoulder.isPressed),
            (.leftTrigger, pad.leftTrigger.isPressed), (.rightTrigger, pad.rightTrigger.isPressed),
            (.leftStick, pad.leftThumbstickButton?.isPressed ?? false),
            (.rightStick, pad.rightThumbstickButton?.isPressed ?? false),
            (.menu, pad.buttonMenu.isPressed), (.options, pad.buttonOptions?.isPressed ?? false)
        ]
        let pressedButtons = Set(inputs.filter { $0.1 }.map { $0.0 })
        let menuResult = quickMenuChord.update(pressed: pressedButtons, pair: [.leftShoulder, .rightShoulder, .south])
        if menuResult.switched {
            quickMenuVisible = true
            dstv_set_buttons(0); return
        }
        let chordResult = gamepadChord.update(pressed: pressedButtons.subtracting(menuResult.consumed), pair: settings.values.gamepadScreenShortcut.buttons)
        screenSwitchPressed = screenSwitchPressed || chordResult.switched
        for (button, pressed) in inputs where pressed && !chordResult.consumed.contains(button) && !menuResult.consumed.contains(button) {
            let binding: InputBinding
            if dstv_is_psp() == 1, settings.values.gamepadMappings[button] == nil {
                switch button {
                case .south: binding = .b // Cross
                case .east: binding = .a // Circle
                case .west: binding = .y // Square
                case .north: binding = .x // Triangle
                default: binding = settings.values.gamepadBinding(for: button, shapeLabels: usesShapeLabels)
                }
            } else { binding = settings.values.gamepadBinding(for: button, shapeLabels: usesShapeLabels) }
            include(binding, in: &buttons)
        }
        if dstv_is_3ds() == 1 || dstv_is_psp() == 1 {
            func axis(_ value: Float) -> Int16 { Int16(max(-1, min(1, value)) * 32767) }
            dstv_set_analog(axis(pad.leftThumbstick.xAxis.value), axis(-pad.leftThumbstick.yAxis.value),
                            axis(pad.rightThumbstick.xAxis.value), axis(-pad.rightThumbstick.yAxis.value))
        } else {
            buttons |= movementStick.update(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value)
        }
        let directions: [(Int, Bool)] = [
            (4, pad.dpad.up.isPressed), (5, pad.dpad.down.isPressed),
            (6, pad.dpad.left.isPressed), (7, pad.dpad.right.isPressed)
        ]
        for (id, pressed) in directions where pressed { buttons |= 1 << id }
        dstv_set_buttons(buttons)
    }

    private func remoteDirections(_ snapshot: GCMicroGamepad?) -> UInt16 {
        guard let pad = snapshot else { return 0 }
        // Modern remotes expose distinct ring clicks and a center button.
        // Prefer these so a direction click doesn't also press DS A.
        let cardinal = pad.dpads[GCInputDirectionalCardinalDpad]
        let direction = cardinal ?? pad.dpad
        let inputs: [(Int, Bool)] = [
            (4, direction.up.isPressed), (5, direction.down.isPressed),
            (6, direction.left.isPressed), (7, direction.right.isPressed),
            // Remappable actions are combined below; directions stay fixed.
        ]
        var buttons: UInt16 = 0
        for (id, pressed) in inputs where pressed { buttons |= 1 << id }
        return buttons
    }

    func pressRemote(_ button: RemoteButton) {
        pulses.press(button)
        #if DEBUG
        print("Remote event: \(button.rawValue) -> \(settings.values.mapping(for: button).rawValue)")
        #endif
    }

    func releaseControllers() {
        clear()
        selected?.extendedGamepad?.buttonX.preferredSystemGestureState = .enabled
        selected?.extendedGamepad?.buttonB.preferredSystemGestureState = .enabled
        selected?.extendedGamepad?.buttonMenu.preferredSystemGestureState = .enabled
        selected?.extendedGamepad?.buttonOptions?.preferredSystemGestureState = .enabled
        remote?.microGamepad?.buttonMenu.pressedChangedHandler = nil
        remote?.microGamepad?.buttonMenu.preferredSystemGestureState = .enabled
        selected = nil; remote = nil
    }

    func clear() {
        pulses.clear()
        movementStick.clear()
        gamepadChord.clear()
        remoteChord.clear()
        screenSwitchPressed = false
        actions = 0
        previousActions = 0
        actionEdges = 0
        dstv_set_buttons(0)
        dstv_set_analog(0, 0, 0, 0)
    }
}
