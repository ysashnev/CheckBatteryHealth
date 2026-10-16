import CoreBluetooth

/// Опис протоколу конкретного BMS, що працює через BLE.
protocol BMSProtocol: AnyObject {
    /// GATT-сервіс, за яким протокол розпізнається.
    static var serviceUUID: CBUUID { get }
    static var displayName: String { get }

    init()

    /// Характеристика, з якої приходять відповіді (notify / read).
    var notifyUUID: CBUUID { get }
    /// Характеристика для запитів; `nil`, якщо протокол лише читає.
    var writeUUID: CBUUID? { get }
    /// Чи треба на кожному опитуванні робити read характеристики notify.
    var readOnPoll: Bool { get }

    /// Запити, які надсилаються на кожному циклі опитування.
    func pollRequests() -> [Data]

    /// Обробляє отримані байти. Повертає `true`, якщо `reading` оновлено.
    func handle(_ bytes: [UInt8], reading: inout BatteryReading) -> Bool
}

enum BMSRegistry {
    /// Порядок важливий: перший збіг сервісу перемагає.
    static let all: [BMSProtocol.Type] = [
        JBDProtocol.self,
        DalyProtocol.self,
        StandardBatteryProtocol.self,
    ]

    static func protocolType(for services: [CBUUID]) -> BMSProtocol.Type? {
        all.first { services.contains($0.serviceUUID) }
    }

    /// Здогадка за рекламними даними — лише для підказки у списку пристроїв.
    static func guess(advertised: [CBUUID], name: String?) -> String? {
        if let type = protocolType(for: advertised) { return type.displayName }
        let lower = (name ?? "").lowercased()
        if lower.hasPrefix("xiaoxiang") || lower.hasPrefix("jbd") || lower.hasPrefix("sp") {
            return JBDProtocol.displayName
        }
        if lower.hasPrefix("dl-") || lower.contains("daly") {
            return DalyProtocol.displayName
        }
        return nil
    }
}

extension Array where Element == UInt8 {
    func u16(_ i: Int) -> Int { Int(self[i]) << 8 | Int(self[i + 1]) }
    func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(i)))) }
    func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
}
