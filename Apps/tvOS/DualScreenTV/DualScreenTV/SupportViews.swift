import SwiftUI
import GameController

struct WelcomeView: View {
    let done: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Welcome to DualScreenTV").font(.system(size: 48, weight: .semibold, design: .rounded))
                Text("Make yourself comfortable. Your games live here.").font(.title3).foregroundStyle(.secondary)
                help("Bring a game", "Choose Add/Edit Games, then open the local address in a browser or the companion app. Enter the code shown on the TV and upload your own supported game files.", icon: "plus.circle")
                help("Play your way", "Connect a controller in Apple TV Settings. During play, LB + RB + A opens the game menu. Check your buttons in Controller & Game Info.", icon: "gamecontroller")
                help("Add a second screen", "The iPad or Mac companion is optional. Pair with the iPad Companion code for a touchscreen and on-screen controls. Its settings gear opens the game menu too.", icon: "ipad.and.arrow.forward")
                help("Keep your progress", "Use the game's own save feature. Local backup history helps recover mistakes, but tvOS may clear local storage. Export important saves through Add/Edit Games to another device.", icon: "externaldrive.badge.checkmark")
                help("Find the right fit", "Each game remembers its graphics, display, speed and controller settings. Start with native resolution, then increase it if play and audio stay smooth. Save-state support varies by core.", icon: "slider.horizontal.3")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Systems & compatibility").font(.title3)
                    Text("GB / GBC / GBA: mGBA · .gb, .gbc, .gba\nNintendo DS: melonDS, DeSmuME or Dust · .nds\nNintendo 3DS: Azahar · decrypted .cci, .3ds, .cxi or .3dsx homebrew\nPSP: PPSSPP · .iso, .cso, .pbp").lineSpacing(8)
                    Text("Games vary in compatibility and speed. DS cores use separate saves. Save states currently work with melonDS, mGBA and PPSSPP; other integrations use in-game saves. No games or proprietary firmware dumps are included.").font(.caption).foregroundStyle(.secondary)
                }.tvStudioPanel()
                ControllerDiagram()
                Button("Let's play", action: done)
            }.padding(60).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }.background(TVStudioBackground()).buttonStyle(TVStudioButtonStyle())
    }
    private func help(_ title: String, _ text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.title3)
            Text(text).font(.body).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).tvStudioPanel().focusable()
    }
}

struct ControllerDiagram: View {
    var isPSP = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { _ in
            let controller = GCController.controllers().first { $0.extendedGamepad != nil }
            let pad = controller?.capture().extendedGamepad
            let preferences = FrontendPreferences.read(from: .standard)
            let shape = pad?.buttonY.sfSymbolsName?.contains("triangle") == true
            VStack(spacing: 18) {
                Text(controller?.vendorName ?? "Controller preview").font(.system(size: 28, weight: .semibold, design: .rounded))
                HStack(spacing: 120) {
                    HStack { key("LB / L1", pad?.leftShoulder.isPressed ?? false); key("LT / L2", pad?.leftTrigger.isPressed ?? false) }
                    HStack { key("RT / R2", pad?.rightTrigger.isPressed ?? false); key("RB / R1", pad?.rightShoulder.isPressed ?? false) }
                }
                ZStack {
                    chassis.frame(width: 820, height: 340)
                    HStack(spacing: 70) {
                        VStack(spacing: 14) {
                            stick(pad?.leftThumbstick.xAxis.value ?? 0, pad?.leftThumbstick.yAxis.value ?? 0, pressed: pad?.leftThumbstickButton?.isPressed ?? false)
                            VStack(spacing: 3) {
                                arrow("↑", pad?.dpad.up.isPressed ?? false)
                                HStack(spacing: 3) { arrow("←", pad?.dpad.left.isPressed ?? false); arrow("↓", pad?.dpad.down.isPressed ?? false); arrow("→", pad?.dpad.right.isPressed ?? false) }
                            }
                        }
                        VStack(spacing: 20) {
                            key("Menu / Start", pad?.buttonMenu.isPressed ?? false)
                            key("View / Select", pad?.buttonOptions?.isPressed ?? false)
                        }
                        VStack(spacing: 14) {
                            ZStack {
                                face(shape ? "△" : "Y", pad?.buttonY.isPressed ?? false).offset(y: -51)
                                face(shape ? "□" : "X", pad?.buttonX.isPressed ?? false).offset(x: -51)
                                face(shape ? "○" : "B", pad?.buttonB.isPressed ?? false).offset(x: 51)
                                face(shape ? "×" : "A", pad?.buttonA.isPressed ?? false).offset(y: 51)
                            }.frame(width: 155, height: 155)
                            stick(pad?.rightThumbstick.xAxis.value ?? 0, pad?.rightThumbstick.yAxis.value ?? 0, pressed: pad?.rightThumbstickButton?.isPressed ?? false)
                        }
                    }
                }.frame(height: 340)
                Text("A / × → " + action(.south, preferences, shape) + "    B / ○ → " + action(.east, preferences, shape) + "    X / □ → " + action(.west, preferences, shape) + "    Y / △ → " + action(.north, preferences, shape))
                    .font(.system(size: 21, weight: .medium)).lineLimit(2)
                if pad == nil {
                    Text("Connect a controller in Apple TV Settings → Remotes and Devices → Bluetooth to test its buttons.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Press buttons or move the sticks to see your input. Face-button actions are listed above.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity).tvStudioPanel().focusable()
        }
    }
    private var chassis: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let point: (Double, Double) -> CGPoint = { CGPoint(x: CGFloat($0) * size.width, y: CGFloat($1) * size.height) }
            let body = Path { path in
                path.move(to: point(0.26, 0.10))
                path.addCurve(to: point(0.10, 0.28), control1: point(0.18, 0.06), control2: point(0.12, 0.16))
                path.addCurve(to: point(0.04, 0.88), control1: point(0.07, 0.43), control2: point(0.00, 0.80))
                path.addCurve(to: point(0.19, 0.94), control1: point(0.08, 1.00), control2: point(0.15, 1.00))
                path.addLine(to: point(0.34, 0.69))
                path.addQuadCurve(to: point(0.42, 0.63), control: point(0.37, 0.62))
                path.addLine(to: point(0.58, 0.63))
                path.addQuadCurve(to: point(0.66, 0.69), control: point(0.63, 0.62))
                path.addLine(to: point(0.81, 0.94))
                path.addCurve(to: point(0.96, 0.88), control1: point(0.85, 1.00), control2: point(0.92, 1.00))
                path.addCurve(to: point(0.90, 0.28), control1: point(1.00, 0.80), control2: point(0.93, 0.43))
                path.addCurve(to: point(0.74, 0.10), control1: point(0.88, 0.16), control2: point(0.82, 0.06))
                path.addQuadCurve(to: point(0.26, 0.10), control: point(0.50, 0.17))
                path.closeSubpath()
            }
            body.fill(.white.opacity(0.07)).overlay(body.stroke(.white.opacity(0.18), lineWidth: 2))
        }
    }
    private func face(_ label: String, _ pressed: Bool) -> some View {
        Text(label).font(.system(size: 23, weight: .semibold, design: .rounded)).frame(width: 50, height: 50)
            .foregroundStyle(pressed ? .black : .white)
            .background(pressed ? Color.white : Color(white: 0.15), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.2)))
    }
    private func arrow(_ label: String, _ pressed: Bool) -> some View {
        Text(label).font(.system(size: 23, weight: .semibold)).frame(width: 43, height: 43)
            .foregroundStyle(pressed ? .black : .white)
            .background(pressed ? Color.white : Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
    }
    private func stick(_ x: Float, _ y: Float, pressed: Bool) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.45)).overlay(Circle().stroke(.white.opacity(0.2)))
            Circle().fill(pressed ? Color.white : Color(white: 0.25)).frame(width: 50, height: 50)
                .offset(x: CGFloat(x) * 18, y: CGFloat(-y) * 18)
        }.frame(width: 82, height: 82)
    }
    private func action(_ button: GamepadButton, _ preferences: FrontendPreferences, _ shape: Bool) -> String {
        var binding = preferences.gamepadBinding(for: button, shapeLabels: shape)
        if isPSP && preferences.gamepadMappings[button] == nil {
            switch button { case .south: binding = .b; case .east: binding = .a; case .west: binding = .y; case .north: binding = .x; default: break }
        }
        if isPSP {
            switch binding { case .a: return "Circle"; case .b: return "Cross"; case .x: return "Triangle"; case .y: return "Square"; default: break }
        }
        switch binding {
        case .none: return "Unmapped"
        case .fastForward: return "Fast forward"
        case .saveState: return "Save state"
        case .loadState: return "Load state"
        case .switchScreen: return "Swap screens"
        default: return binding.rawValue.uppercased()
        }
    }
    private func key(_ label: String, _ pressed: Bool) -> some View {
        Text(label).font(.system(size: 19, weight: .semibold, design: .rounded)).padding(12)
            .foregroundStyle(pressed ? .black : .white)
            .background(pressed ? Color.white : Color.white.opacity(0.07), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15)))
    }
}
struct GameSupportView: View {
    let report: String
    var isPSP = false
    let done: () -> Void
    @State private var showReport = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your controller").font(.system(size: 40, weight: .semibold, design: .rounded))
                ControllerDiagram(isPSP: isPSP)
                HStack(spacing: 24) {
                    Button("Back to Game Menu", action: done)
                    Button(showReport ? "Hide Game Report" : "View Game Report") { showReport.toggle() }
                }
                if showReport {
                    Text(report).font(.system(size: 22)).lineSpacing(8).tvStudioPanel().focusable()
                }
            }.padding(50).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }.background(TVStudioBackground()).buttonStyle(TVStudioButtonStyle())
    }
}
