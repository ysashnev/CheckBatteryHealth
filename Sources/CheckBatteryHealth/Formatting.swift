import Foundation

enum Fmt {
    static func number(_ value: Double?, digits: Int, unit: String) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f %@", value, unit)
    }

    /// Потужність без знаку (напрям показує іконка заряду/розряду).
    static func power(_ watts: Double?) -> String? {
        guard let watts else { return nil }
        return String(format: "%.0f Вт", abs(watts))
    }

    static func duration(hours: Double) -> String {
        guard hours.isFinite, hours >= 0 else { return "—" }
        let totalMinutes = Int((hours * 60).rounded())
        let days = totalMinutes / 1440
        let h = (totalMinutes % 1440) / 60
        let m = totalMinutes % 60
        if days > 0 { return "\(days) д \(h) год" }
        if h > 0 { return "\(h) год \(m) хв" }
        return "\(m) хв"
    }
}
