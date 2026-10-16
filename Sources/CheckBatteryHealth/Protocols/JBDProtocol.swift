import CoreBluetooth

/// JBD / Xiaoxiang BMS (найпоширеніший у LiFePO4-батареях з Bluetooth).
/// Сервіс FF00, notify FF01, write FF02.
/// Кадр: DD <cmd> <status> <len> <data…> <chkH> <chkL> 77
final class JBDProtocol: BMSProtocol {
    static let serviceUUID = CBUUID(string: "FF00")
    static let displayName = "JBD / Xiaoxiang"

    let notifyUUID = CBUUID(string: "FF01")
    let writeUUID: CBUUID? = CBUUID(string: "FF02")
    let readOnPoll = false

    private enum Command: UInt8 {
        case basicInfo = 0x03
        case cellVoltages = 0x04
    }

    private var buffer: [UInt8] = []

    init() {}

    func pollRequests() -> [Data] {
        [Self.readRequest(.basicInfo), Self.readRequest(.cellVoltages)]
    }

    private static func readRequest(_ command: Command) -> Data {
        let body: [UInt8] = [command.rawValue, 0x00]
        let checksum = checksum(body)
        return Data([0xDD, 0xA5] + body + [UInt8(checksum >> 8), UInt8(checksum & 0xFF), 0x77])
    }

    private static func checksum(_ bytes: some Sequence<UInt8>) -> Int {
        (0x10000 - bytes.reduce(0) { $0 + Int($1) }) & 0xFFFF
    }

    func handle(_ bytes: [UInt8], reading: inout BatteryReading) -> Bool {
        buffer += bytes
        var updated = false

        while true {
            guard let start = buffer.firstIndex(of: 0xDD) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 4 else { break }

            let length = Int(buffer[3])
            let frameLength = 4 + length + 3
            guard buffer.count >= frameLength else {
                if buffer.count > 512 { buffer.removeAll() }
                break
            }

            let frame = Array(buffer[0..<frameLength])
            buffer.removeFirst(frameLength)

            guard frame[frameLength - 1] == 0x77, frame[2] == 0x00 else { continue }
            let expected = Int(frame[4 + length]) << 8 | Int(frame[5 + length])
            guard Self.checksum(frame[2..<(4 + length)]) == expected else { continue }

            let payload = Array(frame[4..<(4 + length)])
            switch Command(rawValue: frame[1]) {
            case .basicInfo:
                updated = parseBasicInfo(payload, into: &reading) || updated
            case .cellVoltages:
                reading.cellVoltages = stride(from: 0, to: payload.count - 1, by: 2)
                    .map { Double(payload.u16($0)) / 1000 }
                updated = true
            case nil:
                break
            }
        }
        return updated
    }

    private func parseBasicInfo(_ p: [UInt8], into reading: inout BatteryReading) -> Bool {
        guard p.count >= 23 else { return false }
        reading.voltage = Double(p.u16(0)) / 100
        reading.current = Double(p.s16(2)) / 100
        reading.remainingAh = Double(p.u16(4)) / 100
        reading.nominalAh = Double(p.u16(6)) / 100
        reading.cycles = p.u16(8)
        reading.protectionFlags = p.u16(16)
        reading.soc = Double(p[19])
        reading.chargeEnabled = p[20] & 0x01 != 0
        reading.dischargeEnabled = p[20] & 0x02 != 0

        let ntcCount = Int(p[22])
        reading.temperatures = (0..<ntcCount).compactMap { i in
            let offset = 23 + i * 2
            guard offset + 1 < p.count else { return nil }
            return (Double(p.u16(offset)) - 2731) / 10
        }
        return true
    }
}
