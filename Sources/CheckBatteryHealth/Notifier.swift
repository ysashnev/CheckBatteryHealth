import Foundation
import UserNotifications

/// Системні сповіщення (про низький заряд).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let shared = Notifier()

    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Notifier: \(error.localizedDescription)") }
        }
    }

    static func lowBattery(id: UUID, name: String, reading: BatteryReading) {
        let content = UNMutableNotificationContent()
        content.title = "Низький заряд: \(name)"
        var body = "Залишилось \(Int((reading.soc ?? 0).rounded()))%"
        if let hours = reading.hoursToEmpty {
            body += " — приблизно на \(Fmt.duration(hours: hours))"
        }
        if let power = Fmt.power(reading.power), reading.isDischarging {
            body += " при \(power)"
        }
        content.body = body + "."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-\(id.uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Показувати банер, навіть коли застосунок активний (відкрите вікно в рядку меню).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
