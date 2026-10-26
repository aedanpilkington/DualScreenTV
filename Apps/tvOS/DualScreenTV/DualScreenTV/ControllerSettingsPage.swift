import SwiftUI

struct ControllerSettingsPage: View {
    let openSystemSettings: () -> Void
    let done: () -> Void
    @State private var previewPSP = false
    @StateObject private var settings = AppSettings()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Controller Settings").font(.system(size: 42, weight: .semibold, design: .rounded))
                HStack(spacing: 24) {
                    Button("Done", action: done)
                    Button("Apple TV App Settings", action: openSystemSettings)
                }
                ControllerDiagram(isPSP: previewPSP)
                Toggle("Preview PSP face-button layout", isOn: $previewPSP)
                Text("Button mappings").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Defaults for new games. Existing games keep their own mappings.").font(.caption).foregroundStyle(.secondary)
                ForEach(GamepadButton.allCases, id: \.rawValue) { button in
                    Picker(label(button), selection: Binding(get: {
                        settings.values.gamepadMappings[button]?.rawValue ?? "default"
                    }, set: { value in
                        UserDefaults.standard.set(value, forKey: button.key); settings.reload()
                    })) {
                        Text("Default").tag("default")
                        ForEach(InputBinding.allCases, id: \.rawValue) { Text(bindingName($0)).tag($0.rawValue) }
                    }
                }
                Button("Open Apple TV App Settings", action: openSystemSettings)
                Button("Done", action: done)
            }.padding(60).frame(maxWidth: 1450).frame(maxWidth: .infinity)
        }.background(TVStudioBackground()).foregroundStyle(.white).buttonStyle(TVStudioButtonStyle())
        .onAppear { settings.reload() }
        .onChange(of: phase) { if $0 == .active { settings.reload() } }
        .onExitCommand(perform: done)
    }
    private func label(_ button: GamepadButton) -> String {
        switch button {
        case .south: "Bottom face · A / Cross"
        case .east: "Right face · B / Circle"
        case .west: "Left face · X / Square"
        case .north: "Top face · Y / Triangle"
        case .leftShoulder: "Left shoulder · LB / L1"
        case .rightShoulder: "Right shoulder · RB / R1"
        case .leftTrigger: "Left trigger · LT / L2"
        case .rightTrigger: "Right trigger · RT / R2"
        case .leftStick: "Left stick click"
        case .rightStick: "Right stick click"
        case .menu: "Menu / Start"
        case .options: "View / Select"
        }
    }
    private func bindingName(_ binding: InputBinding) -> String {
        switch binding {
        case .none: "Unmapped"
        case .fastForward: "Fast Forward"
        case .saveState: "Save State"
        case .loadState: "Load State"
        case .switchScreen: "Swap Screens"
        case .pause: "Pause"
        case .reset: "Reset"
        default: binding.rawValue.uppercased()
        }
    }
}
