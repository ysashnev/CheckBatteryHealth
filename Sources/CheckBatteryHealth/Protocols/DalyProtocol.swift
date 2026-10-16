import CoreBluetooth

/// Daly Smart BMS (класичний протокол A5).
/// Сервіс FFF0, notify FFF1, write FFF2.
/// Кадр (13 байт): A5 <addr> <cmd> 08 <8 байт даних> <checksum>
final class DalyProtocol: BMSProtocol {
    static let serviceUUID = CBUUID(string: "FFF0")
    static let displayName = "Daly"

    let notifyUUID = CBUUID(string: "FFF1")
    let writeUUID: CBUUID? = CBUUID(string: "FFF2")
    let readOnPoll = false

    private enum Command: UInt8 {
        case ratedCapacity = 0x50
        case socVoltageCurrent = 0x90
        case temperature = 0x92
        case mosfetStatus = 0x93
        case statusInfo = 0x94
        case cellVoltages = 0x95
    }

    private static let frameLength = 13
    private var buffer: [UInt8] = []
    private var cellCount = 0
    private var cells: [Double] = []
    private var pollCount = 0

    init() {}

    func pollRequests() -> [Data] {
        var commands: [Command] = [.socVoltageCurrent, .mosfetStatus, .temperature, .cellVoltages]
        // Номінальну ємність і кількість комірок достатньо читати зрідка.
        if pollCount % 20 == 0 { commands += [.ratedCapacity, .statusInfo] }
        pollCount += 1
        return commands.map(Self.request)
    }

    private static func request(_ command: Command) -> Data {
        var frame: [UInt8] = [0xA5, 0x80, command.rawValue, 0x08] + Array(repeating: 0, count: 8)
        frame.append(UInt8(frame.reduce(0) { $0 + Int($1) } & 0xFF))
        return Data(frame)
    }

    func handle(_ bytes: [UInt8], reading: inout BatteryReading) -> Bool {
        buffer += bytes
        var updated = false

        while true {
            guard let start = buffer.firstIndex(of: 0xA5) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= Self.frameLength else { break }

            let frame = Array(buffer[0..<Self.frameLength])
            let sum = frame[0..<12].reduce(0) { $0 + Int($1) } & 0xFF
            guard frame[3] == 0x08, sum == Int(frame[12]) else {
                buffer.removeFirst() // зсуваємось і шукаємо наступний A5
                continue
            }
            buffer.removeFirst(Self.frameLength)

            let d = Array(frame[4..<12])
            switch Command(rawValue: frame[2]) {
            case .socVoltageCurrent:
                reading.voltage = Double(d.u16(0)) / 10
                reading.current = Double(d.u16(4) - 30000) / 10
                reading.soc = Double(d.u16(6)) / 10
                updated = true
            case .temperature:
                let maxT = Double(Int(d[0]) - 40)
                let minT = Double(Int(d[2]) - 40)
                reading.temperatures = maxT == minT ? [maxT] : [maxT, minT]
                updated = true
            case .mosfetStatus:
                reading.chargeEnabled = d[1] != 0
                reading.dischargeEnabled = d[2] != 0
                reading.remainingAh = Double(d.u32(4)) / 1000
                updated = true
            case .statusInfo:
                cellCount = Int(d[0])
            case .ratedCapacity:
                let rated = Double(d.u32(0)) / 1000
                if rated > 0 {
                    reading.nominalAh = rated
                    updated = true
                }
            case .cellVoltages:
                // Кожен кадр: номер кадру (з 1) + 3 комірки по 2 байти.
                let frameNo = Int(d[0])
                guard frameNo >= 1, cellCount > 0 else { break }
                if cells.count != cellCount { cells = Array(repeating: 0, count: cellCount) }
                for i in 0..<3 {
                    let index = (frameNo - 1) * 3 + i
                    guard index < cellCount else { break }
                    cells[index] = Double(d.u16(1 + i * 2)) / 1000
                }
                if frameNo * 3 >= cellCount, !cells.contains(0) {
                    reading.cellVoltages = cells
                    updated = true
                }
            case nil:
                break
            }
        }
        return updated
    }
}
