import CoreBluetooth

/// Стандартний BLE Battery Service (0x180F) — лише рівень заряду у відсотках.
/// Запасний варіант для пристроїв без «розумного» BMS-протоколу.
final class StandardBatteryProtocol: BMSProtocol {
    static let serviceUUID = CBUUID(string: "180F")
    static let displayName = "BLE Battery Service"

    let notifyUUID = CBUUID(string: "2A19")
    let writeUUID: CBUUID? = nil
    let readOnPoll = true

    init() {}

    func pollRequests() -> [Data] { [] }

    func handle(_ bytes: [UInt8], reading: inout BatteryReading) -> Bool {
        guard let level = bytes.first else { return false }
        reading.soc = Double(level)
        return true
    }
}
