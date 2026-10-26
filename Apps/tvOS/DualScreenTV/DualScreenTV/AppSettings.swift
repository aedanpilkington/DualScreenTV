import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var values: FrontendPreferences
    init() {
        UserDefaults.standard.register(defaults: FrontendPreferences.registeredDefaults)
        values = FrontendPreferences.read(from: .standard)
    }
    func toggleScreen() {
        UserDefaults.standard.set(values.screen == .top ? "bottom" : "top", forKey: "display.screen")
        reload()
    }
    func setGameVolume(_ percent: Int) {
        UserDefaults.standard.set(min(100, max(0, percent)), forKey: "audio.volume")
        UserDefaults.standard.set(false, forKey: "audio.mute")
        reload()
    }
    func reload() {
        GamePreferences.capture()
        let updated = FrontendPreferences.read(from: .standard)
        if updated != values { values = updated }
        #if DEBUG
        print("Top display: \(values.topMode.rawValue), overscan \(values.topOverscanPercent)%")
        #endif
    }
}
