import CoreBluetooth
import Foundation

/// З'єднання з BMS одного акумулятора: підключення, визначення протоколу,
/// опитування і перепідключення. Колбеки CoreBluetooth приходять на головну чергу.
final class BatteryLink: NSObject, ObservableObject, Identifiable {
    enum State: Equatable {
        case idle, connecting, discovering, connected
    }

    let id: UUID
    @Published private(set) var name: String
    @Published private(set) var state: State = .idle
    @Published private(set) var reading = BatteryReading()
    @Published private(set) var protocolName: String?
    @Published private(set) var message: String?

    var isConnected: Bool { state == .connected }
    /// Користувач сам від'єднався — не перепідключаємось автоматично.
    private(set) var manualDisconnect = false
    private(set) var peripheral: CBPeripheral?

    var pollInterval: Double {
        didSet { if state == .connected { startPolling() } }
    }

    /// Викликається, коли пристрій повідомив свою назву (для збереження).
    var onNameChange: ((String) -> Void)?

    private unowned let central: CBCentralManager
    private var bms: BMSProtocol?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pollTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?

    init(id: UUID, name: String, central: CBCentralManager, pollInterval: Double) {
        self.id = id
        self.name = name
        self.central = central
        self.pollInterval = pollInterval
        super.init()
    }

    // MARK: - Public API

    func connect(_ target: CBPeripheral) {
        reconnectWorkItem?.cancel()
        resetLink()
        manualDisconnect = false
        peripheral = target
        if let name = target.name { updateName(name) }
        state = .connecting
        message = nil
        // На macOS запит на з'єднання не має тайм-ауту: підключимось, щойно
        // акумулятор з'явиться в зоні досяжності.
        central.connect(target, options: nil)
    }

    func disconnect() {
        manualDisconnect = true
        reconnectWorkItem?.cancel()
        resetLink()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        state = .idle
        message = nil
    }

    /// Від'єднатися назавжди (пристрій забуто).
    func tearDown() {
        disconnect()
        peripheral?.delegate = nil
        peripheral = nil
    }

    func refreshNow() {
        poll()
    }

    func setMessage(_ text: String?) {
        message = text
    }

    // MARK: - Події від BluetoothManager

    func didConnect() {
        state = .discovering
        message = nil
        guard let peripheral else { return }
        if let name = peripheral.name { updateName(name) }
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func didFailToConnect(_ error: Error?) {
        resetLink()
        state = .idle
        message = "Не вдалося підключитися: \(error?.localizedDescription ?? "невідома помилка")"
        scheduleReconnect(after: 5)
    }

    func didDisconnect() {
        resetLink()
        state = .idle
        if !manualDisconnect {
            message = "З'єднання втрачено, перепідключаюсь…"
            scheduleReconnect(after: 2)
        }
    }

    func bluetoothPoweredOff() {
        reconnectWorkItem?.cancel()
        resetLink()
        state = .idle
    }

    // MARK: - Private

    private func updateName(_ newName: String) {
        guard newName != name else { return }
        name = newName
        onNameChange?(newName)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard !manualDisconnect, let target = peripheral else { return }
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.central.state == .poweredOn else { return }
            self.state = .connecting
            self.central.connect(target, options: nil)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func resetLink() {
        stopPolling()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        bms = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        poll()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard let peripheral, peripheral.state == .connected, let bms else { return }

        if bms.readOnPoll, let notify = notifyCharacteristic, notify.properties.contains(.read) {
            peripheral.readValue(for: notify)
        }

        guard let write = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType =
            write.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        // BMS погано переносять кілька запитів поспіль — робимо паузу між ними.
        for (index, request) in bms.pollRequests().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) { [weak self] in
                guard let self, let p = self.peripheral, p.state == .connected,
                      self.writeCharacteristic === write else { return }
                p.writeValue(request, for: write, type: type)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BatteryLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, error == nil else {
            message = "Помилка пошуку сервісів: \(error?.localizedDescription ?? "—")"
            return
        }
        let uuids = services.map(\.uuid)
        guard let type = BMSRegistry.protocolType(for: uuids),
              let service = services.first(where: { $0.uuid == type.serviceUUID }) else {
            let list = uuids.map(\.uuidString).joined(separator: ", ")
            message = "Невідомий BMS. Сервіси пристрою: \(list)"
            return
        }
        bms = type.init()
        protocolName = type.displayName
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let bms, let characteristics = service.characteristics, error == nil else {
            message = "Помилка пошуку характеристик: \(error?.localizedDescription ?? "—")"
            return
        }
        guard let notify = characteristics.first(where: { $0.uuid == bms.notifyUUID }) else {
            message = "Не знайдено характеристику \(bms.notifyUUID.uuidString)"
            return
        }
        notifyCharacteristic = notify
        writeCharacteristic = bms.writeUUID.flatMap { uuid in
            characteristics.first { $0.uuid == uuid }
        }
        if bms.writeUUID != nil, writeCharacteristic == nil {
            message = "Не знайдено характеристику для запитів"
            return
        }
        if notify.properties.contains(.notify) || notify.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: notify)
        }
        state = .connected
        startPolling()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let bms, let data = characteristic.value,
              characteristic.uuid == bms.notifyUUID else { return }
        var updated = reading
        if bms.handle([UInt8](data), reading: &updated) {
            updated.updatedAt = Date()
            reading = updated
        }
    }
}
