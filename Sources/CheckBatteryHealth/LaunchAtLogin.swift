import Foundation
import ServiceManagement

enum LaunchAtLogin {
    private static let configuredKey = "launchAtLoginConfigured"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS чекає, поки користувач дозволить автозапуск у «Об'єктах входу».
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin: \(error.localizedDescription)")
        }
    }

    /// Вмикає автозапуск один раз — при першому запуску. Якщо користувач потім
    /// вимкне його в налаштуваннях, більше не вмикаємо.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: configuredKey) else { return }
        set(true)
        defaults.set(true, forKey: configuredKey)
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
