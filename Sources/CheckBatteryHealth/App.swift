import SwiftUI

@main
struct CheckBatteryHealthApp: App {
    @StateObject private var manager = BluetoothManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(manager)
        } label: {
            MenuBarLabel(manager: manager)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Іконка + відсоток у рядку меню.
struct MenuBarLabel: View {
    @ObservedObject var manager: BluetoothManager

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            Text(title)
        }
    }

    private var title: String {
        guard let soc = manager.reading.soc else { return "—" }
        return "\(Int(soc.rounded()))%"
    }

    private var symbolName: String {
        guard manager.isConnected, let soc = manager.reading.soc else {
            return "battery.0"
        }
        if manager.reading.isCharging { return "battery.100.bolt" }
        switch soc {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
