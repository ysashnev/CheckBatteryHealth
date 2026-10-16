import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @State private var showDevices = false
    @State private var showCells = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let message = manager.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if manager.reading.updatedAt != nil {
                Divider()
                ReadingView(reading: manager.reading, showCells: $showCells)
            } else if manager.savedPeripheralID != nil {
                Text(placeholderText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if showDevices || manager.savedPeripheralID == nil {
                Divider()
                DeviceListView()
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(manager.deviceName ?? "Акумулятор LiFePO4")
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isConnected {
                Button {
                    manager.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Оновити зараз")
            }
        }
    }

    private var statusText: String {
        switch manager.state {
        case .unknown: return "Ініціалізація Bluetooth…"
        case .poweredOff: return "Bluetooth вимкнено"
        case .unauthorized: return "Немає дозволу на Bluetooth (Системні параметри → Конфіденційність)"
        case .unsupported: return "Bluetooth LE не підтримується"
        case .idle: return manager.savedPeripheralID == nil ? "Пристрій не вибрано" : "Не підключено"
        case .connecting: return "Підключення…"
        case .discovering: return "Визначення BMS…"
        case .connected:
            if let name = manager.protocolName { return "Підключено · \(name)" }
            return "Підключено"
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .connected: return .green
        case .connecting, .discovering: return .yellow
        default: return .red
        }
    }

    private var placeholderText: String {
        switch manager.state {
        case .connecting: return "Чекаю, поки акумулятор буде поруч…"
        case .discovering, .connected: return "Отримую дані…"
        default: return "Немає даних"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Menu {
                Picker("Інтервал оновлення", selection: $manager.pollInterval) {
                    Text("2 с").tag(2.0)
                    Text("5 с").tag(5.0)
                    Text("10 с").tag(10.0)
                    Text("30 с").tag(30.0)
                    Text("1 хв").tag(60.0)
                }
                Toggle("Запускати при вході в систему", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.set($0) }
                ))
                Divider()
                Button(showDevices ? "Сховати список пристроїв" : "Обрати інший пристрій…") {
                    showDevices.toggle()
                    if showDevices && !manager.isScanning { manager.startScan() }
                }
                if manager.savedPeripheralID != nil {
                    if manager.state == .idle {
                        Button("Підключитися") { manager.reconnect() }
                    } else {
                        Button("Від'єднатися") { manager.disconnect(forget: false) }
                    }
                    Button("Забути пристрій") { manager.disconnect(forget: true) }
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button("Вийти") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

// MARK: - Reading

struct ReadingView: View {
    let reading: BatteryReading
    @Binding var showCells: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            socBlock
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                if let hours = reading.hoursToEmpty {
                    row("Залишилось часу", Fmt.duration(hours: hours), emphasized: true)
                } else if let hours = reading.hoursToFull {
                    row("До повного заряду", Fmt.duration(hours: hours), emphasized: true)
                }
                if let remaining = reading.effectiveRemainingAh {
                    let nominal = reading.nominalAh.map { String(format: " / %.0f", $0) } ?? ""
                    row("Залишок ємності", String(format: "%.1f%@ А·год", remaining, nominal))
                }
                if let wh = reading.remainingWh {
                    row("Залишок енергії", String(format: "%.0f Вт·год", wh))
                }
                row("Напруга", Fmt.number(reading.voltage, digits: 2, unit: "В"))
                row("Струм", Fmt.number(reading.current, digits: 2, unit: "А"))
                row("Потужність", Fmt.number(reading.power, digits: 0, unit: "Вт"))
                if !reading.temperatures.isEmpty {
                    row("Температура", reading.temperatures
                        .map { String(format: "%.1f °C", $0) }
                        .joined(separator: ", "))
                }
                if let cycles = reading.cycles {
                    row("Цикли", "\(cycles)")
                }
                if let charge = reading.chargeEnabled, let discharge = reading.dischargeEnabled {
                    row("MOSFET", "заряд \(charge ? "✓" : "✗") · розряд \(discharge ? "✓" : "✗")")
                }
            }
            .font(.callout)

            ForEach(reading.protectionDescriptions, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !reading.cellVoltages.isEmpty {
                cellsBlock
            }

            if let updated = reading.updatedAt {
                Text("Оновлено о \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var socBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(reading.soc.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Label(modeText, systemImage: modeSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max((reading.soc ?? 0) / 100, 0), 1))
                .tint(socColor)
        }
    }

    private var modeText: String {
        if reading.isCharging { return "Заряджається" }
        if reading.isDischarging { return "Розряджається" }
        return "Спокій"
    }

    private var modeSymbol: String {
        if reading.isCharging { return "bolt.fill" }
        if reading.isDischarging { return "arrow.down.circle" }
        return "pause.circle"
    }

    private var socColor: Color {
        switch reading.soc ?? 0 {
        case ..<20: return .red
        case ..<40: return .orange
        default: return .green
        }
    }

    private var cellsBlock: some View {
        DisclosureGroup(isExpanded: $showCells) {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(Array(reading.cellVoltages.enumerated()), id: \.offset) { index, voltage in
                    Text(String(format: "%d: %.3f", index + 1, voltage))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(voltage == reading.cellMax ? Color.blue
                                         : voltage == reading.cellMin ? Color.orange : Color.primary)
                }
            }
            .padding(.top, 4)
        } label: {
            let delta = reading.cellDelta.map { String(format: "Δ %.0f мВ", $0 * 1000) } ?? ""
            Text("Комірки (\(reading.cellVoltages.count))  \(delta)")
                .font(.callout)
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(emphasized ? .semibold : .regular)
                .monospacedDigit()
        }
    }
}
