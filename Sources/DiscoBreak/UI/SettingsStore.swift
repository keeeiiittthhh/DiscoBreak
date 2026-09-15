import Combine
import Foundation
import ServiceManagement

/// Live settings. Changing anything writes settings.json and tells the show to
/// rebuild, so sliders apply immediately instead of needing a relaunch.
final class SettingsStore: ObservableObject {

    @Published var settings: Settings {
        didSet {
            save()
            onChange?(settings)
        }
    }

    var onChange: ((Settings) -> Void)?

    init() {
        settings = Settings.load()
    }

    func save() {
        guard let dir = Settings.supportDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: dir.appendingPathComponent("settings.json"))
    }

    // MARK: - Launch at login

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("DiscoBreak: launch at login failed — %@", error.localizedDescription)
            }
            objectWillChange.send()
        }
    }
}
