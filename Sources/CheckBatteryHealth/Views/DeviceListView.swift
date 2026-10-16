import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject private var manager: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Пристрої поруч")
                    .font(.headline)
                Spacer()
                if manager.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Стоп") { manager.stopScan() }
                } else {
                    Button("Шукати") { manager.startScan() }
                        .disabled(manager.state == .poweredOff || manager.state == .unauthorized)
                }
            }

            if manager.devices.isEmpty {
                Text(manager.isScanning
                     ? "Пошук… Переконайтесь, що акумулятор увімкнений і поруч."
                     : "Натисніть «Шукати», щоб знайти BMS акумулятора.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.devices) { device in
                            DeviceRow(device: device,
                                      isCurrent: device.id == manager.savedPeripheralID) {
                                manager.connect(to: device)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: device.hint != nil ? "battery.75" : "antenna.radiowaves.left.and.right")
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .lineLimit(1)
                    if let hint = device.hint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                }
                Text("\(device.rssi) dBm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
