import AppKit
import CoreBluetooth
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var manager: BluetoothManager
    @State private var cardsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem = bluetoothProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if manager.links.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Акумулятор LiFePO4")
                        .font(.headline)
                    Text("Пристрій не вибрано")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !manager.links.isEmpty {
                // Картки прокручуються, якщо не влазять на екран (вікно в рядку меню
                // не може бути вищим за екран — інакше верх обрізається).
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(manager.links.enumerated()), id: \.element.id) { index, link in
                            if index > 0 { Divider() }
                            BatteryCard(link: link, startExpanded: manager.links.count == 1)
                        }
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geometry.size.height)
                    })
                }
                .frame(height: min(cardsHeight, maxCardsHeight))
                .onPreferenceChange(ContentHeightKey.self) { cardsHeight = $0 }
            }

            Divider()
            DeviceListView()

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        // Без цього вікно в рядку меню не завжди виростає, коли з'являється новий вміст.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Висота екрана мінус рядок меню, пошук, нижня панель і відступи.
    private var maxCardsHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(screen - 200, 200)
    }

    private var bluetoothProblem: String? {
        switch manager.bluetoothState {
        case .unknown:
            if CBManager.authorization == .notDetermined {
                return "Чекаю дозволу на Bluetooth — натисніть «Дозволити» в системному запиті "
                    + "(він може бути на іншому моніторі)."
            }
            return "Ініціалізація Bluetooth…"
        case .poweredOff: return "Bluetooth вимкнено"
        case .unauthorized: return "Немає дозволу на Bluetooth (Системні параметри → Конфіденційність)"
        case .unsupported: return "Bluetooth LE не підтримується"
        case .poweredOn: return nil
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
                Toggle("Показувати час у рядку меню", isOn: $manager.showTimeInMenuBar)
                Toggle("Показувати потужність у рядку меню", isOn: $manager.showPowerInMenuBar)
                Picker("Попереджати про низький заряд", selection: $manager.lowBatteryThreshold) {
                    Text("Нижче 10%").tag(10)
                    Text("Нижче 20%").tag(20)
                    Text("Нижче 30%").tag(30)
                    Text("Нижче 50%").tag(50)
                    Divider()
                    Text("Не попереджати").tag(0)
                }
                Divider()
                Toggle("Запускати при вході в систему", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled || LaunchAtLogin.requiresApproval },
                    set: { LaunchAtLogin.set($0) }
                ))
                if LaunchAtLogin.requiresApproval {
                    Button("Дозволити автозапуск у Системних параметрах…") {
                        LaunchAtLogin.openSystemSettings()
                    }
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

// MARK: - Battery card

/// Один акумулятор: заголовок зі станом і (у розгорнутому вигляді) усі показники.
struct BatteryCard: View {
    @EnvironmentObject private var manager: BluetoothManager
    @ObservedObject var link: BatteryLink
    @State private var expanded: Bool
    @State private var showCells = false

    init(link: BatteryLink, startExpanded: Bool) {
        self.link = link
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if manager.isLow(link.reading) {
                Label("Низький заряд — нижче \(manager.lowBatteryThreshold)%",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if let message = link.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if expanded {
                if link.reading.updatedAt != nil {
                    ReadingView(reading: link.reading, showCells: $showCells)
                } else {
                    Text(placeholderText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !expanded, link.reading.updatedAt != nil {
                        summary
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if link.isConnected {
                Button {
                    link.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Оновити зараз")
            }

            Menu {
                if link.state == .idle {
                    Button("Підключитися") { manager.reconnect(link) }
                } else {
                    Button("Від'єднатися") { manager.disconnect(link) }
                }
                Button("Забути пристрій", role: .destructive) { manager.forget(link) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Короткий підсумок у згорнутому вигляді: режим, відсоток і час.
    private var summary: some View {
        let reading = link.reading
        return HStack(spacing: 4) {
            switch reading.mode {
            case .charging: Image(systemName: "bolt.fill").foregroundStyle(.green)
            case .discharging: Image(systemName: "arrow.down").foregroundStyle(.orange)
            case .idle: EmptyView()
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(reading.soc.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.headline.monospacedDigit())
                let details = [
                    (reading.hoursToEmpty ?? reading.hoursToFull).map { Fmt.duration(hours: $0) },
                    reading.mode == .idle ? nil : Fmt.power(reading.power),
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        switch link.state {
        case .idle: return "Не підключено"
        case .connecting: return "Підключення…"
        case .discovering: return "Визначення BMS…"
        case .connected:
            if let name = link.protocolName { return "Підключено · \(name)" }
            return "Підключено"
        }
    }

    private var statusColor: Color {
        switch link.state {
        case .connected: return .green
        case .connecting, .discovering: return .yellow
        case .idle: return .red
        }
    }

    private var placeholderText: String {
        switch link.state {
        case .connecting: return "Чекаю, поки акумулятор буде поруч…"
        case .discovering, .connected: return "Отримую дані…"
        case .idle: return "Немає даних"
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

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
