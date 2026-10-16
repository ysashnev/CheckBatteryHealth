import SwiftUI

/// Випадаючий список знайдених поруч BMS. Пошук запускається, щойно відкрито вікно
/// (див. AppDelegate.togglePopover).
struct DeviceListView: View {
    @EnvironmentObject private var manager: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    if candidates.isEmpty {
                        Text(manager.isScanning
                             ? "Шукаю… відкрийте список ще раз за кілька секунд"
                             : "Нічого не знайдено")
                    } else {
                        ForEach(candidates) { device in
                            Button {
                                manager.add(device)
                            } label: {
                                Label(itemTitle(device),
                                      systemImage: device.hint != nil
                                          ? "battery.75" : "antenna.radiowaves.left.and.right")
                            }
                        }
                    }
                    Divider()
                    if manager.isScanning {
                        Button("Зупинити пошук") { manager.stopScan() }
                    } else {
                        Button("Шукати знову") { manager.startScan() }
                    }
                } label: {
                    Label(menuTitle, systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!manager.isPoweredOn)

                if manager.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            if manager.scanFinished, candidates.isEmpty {
                Text("Поруч немає інших BMS. Переконайтесь, що акумулятор увімкнений "
                     + "і не підключений до телефона (BMS приймає лише одне з'єднання).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Знайдені пристрої, яких ще немає серед доданих.
    private var candidates: [DiscoveredDevice] {
        manager.devices.filter { !manager.isAdded($0) }
    }

    private var menuTitle: String {
        let base = manager.links.isEmpty ? "Вибрати акумулятор" : "Додати акумулятор"
        return candidates.isEmpty ? base : "\(base) (знайдено \(candidates.count))"
    }

    private func itemTitle(_ device: DiscoveredDevice) -> String {
        var parts = [device.name]
        if let hint = device.hint { parts.append(hint) }
        parts.append("\(device.rssi) dBm")
        return parts.joined(separator: " · ")
    }
}
