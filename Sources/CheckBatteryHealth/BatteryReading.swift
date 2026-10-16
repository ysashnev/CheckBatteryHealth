import Foundation

/// Знімок стану акумулятора, прочитаний з BMS.
/// Струм: додатний — заряд, від'ємний — розряд.
struct BatteryReading: Equatable {
    var voltage: Double?          // В
    var current: Double?          // А
    var soc: Double?              // %
    var remainingAh: Double?      // А·год
    var nominalAh: Double?        // А·год
    var cycles: Int?
    var temperatures: [Double] = []   // °C
    var cellVoltages: [Double] = []   // В
    var chargeEnabled: Bool?
    var dischargeEnabled: Bool?
    var protectionFlags: Int?
    var updatedAt: Date?

    private static let idleThreshold = 0.05

    var isCharging: Bool { (current ?? 0) > Self.idleThreshold }
    var isDischarging: Bool { (current ?? 0) < -Self.idleThreshold }

    enum Mode {
        case charging, discharging, idle
    }

    var mode: Mode {
        if isCharging { return .charging }
        if isDischarging { return .discharging }
        return .idle
    }

    var power: Double? {
        guard let voltage, let current else { return nil }
        return voltage * current
    }

    /// Залишок ємності; якщо BMS не віддає його напряму — рахуємо з SOC.
    var effectiveRemainingAh: Double? {
        if let remainingAh { return remainingAh }
        if let soc, let nominalAh { return nominalAh * soc / 100 }
        return nil
    }

    var remainingWh: Double? {
        guard let ah = effectiveRemainingAh, let voltage else { return nil }
        return ah * voltage
    }

    /// Скільки годин залишилось до повного розряду при поточному споживанні.
    var hoursToEmpty: Double? {
        guard isDischarging, let ah = effectiveRemainingAh, let current else { return nil }
        return ah / -current
    }

    /// Скільки годин до повного заряду при поточному струмі заряду.
    var hoursToFull: Double? {
        guard isCharging, let ah = effectiveRemainingAh, let nominalAh, let current,
              nominalAh > ah else { return nil }
        return (nominalAh - ah) / current
    }

    var cellMin: Double? { cellVoltages.min() }
    var cellMax: Double? { cellVoltages.max() }
    var cellDelta: Double? {
        guard let cellMin, let cellMax else { return nil }
        return cellMax - cellMin
    }

    var protectionDescriptions: [String] {
        guard let flags = protectionFlags, flags != 0 else { return [] }
        let names = [
            "Перенапруга комірки", "Низька напруга комірки",
            "Перенапруга батареї", "Низька напруга батареї",
            "Перегрів при заряді", "Переохолодження при заряді",
            "Перегрів при розряді", "Переохолодження при розряді",
            "Перевищено струм заряду", "Перевищено струм розряду",
            "Коротке замикання", "Помилка AFE-мікросхеми", "Блокування MOSFET",
        ]
        return names.enumerated().compactMap { flags & (1 << $0.offset) != 0 ? $0.element : nil }
    }
}
