import CoreBluetooth
import Foundation

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var hint: String?
}

/// Керує BLE-з'єднанням з BMS акумулятора. Усі колбеки CoreBluetooth
/// приходять на головну чергу, тому @Published-властивості змінюються безпечно.
final class BluetoothManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case unknown, poweredOff, unauthorized, unsupported
        case idle, connecting, discovering, connected
    }

    @Published private(set) var state: ConnectionState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var reading = BatteryReading()
    @Published private(set) var deviceName: String?
    @Published private(set) var protocolName: String?
    @Published private(set) var message: String?

    @Published private(set) var savedPeripheralID: UUID? {
        didSet { defaults.set(savedPeripheralID?.uuidString, forKey: Keys.peripheralID) }
    }

    @Published var pollInterval: Double {
        didSet {
            defaults.set(pollInterval, forKey: Keys.pollInterval)
            if state == .connected { startPolling() }
        }
    }

    var isConnected: Bool { state == .connected }

    private enum Keys {
        static let peripheralID = "savedPeripheralID"
        static let peripheralName = "savedPeripheralName"
        static let pollInterval = "pollInterval"
    }

    private let defaults = UserDefaults.standard
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var bms: BMSProtocol?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pollTimer: Timer?
    private var scanStopWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var manualDisconnect = false

    override init() {
        let storedInterval = UserDefaults.standard.double(forKey: Keys.pollInterval)
        pollInterval = storedInterval > 0 ? storedInterval : 5
        super.init()
        savedPeripheralID = defaults.string(forKey: Keys.peripheralID).flatMap(UUID.init(uuidString:))
        deviceName = defaults.string(forKey: Keys.peripheralName)
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: nil)

        scanStopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanStopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
    }

    func stopScan() {
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil
        if central.isScanning { central.stopScan() }
        isScanning = false
    }

    func connect(to device: DiscoveredDevice) {
        connect(device.peripheral)
    }

    func refreshNow() {
        poll()
    }

    /// Від'єднатися. `forget: true` — також забути збережений пристрій.
    func disconnect(forget: Bool) {
        manualDisconnect = true
        reconnectWorkItem?.cancel()
        stopPolling()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        if forget {
            peripheral = nil
            savedPeripheralID = nil
            deviceName = nil
            protocolName = nil
            reading = BatteryReading()
            defaults.removeObject(forKey: Keys.peripheralName)
        }
        if central.state == .poweredOn { state = .idle }
        message = nil
    }

    /// Повторне підключення до збереженого пристрою.
    func reconnect() {
        guard central.state == .poweredOn else { return }
        if let peripheral {
            connect(peripheral)
        } else if let id = savedPeripheralID {
            if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
                connect(known)
            } else {
                message = "Шукаю збережений пристрій…"
                startScan()
            }
        }
    }

    // MARK: - Connection

    private func connect(_ target: CBPeripheral) {
        stopScan()
        reconnectWorkItem?.cancel()
        stopPolling()

        if let current = peripheral, current.identifier != target.identifier {
            current.delegate = nil
            central.cancelPeripheralConnection(current)
            reading = BatteryReading()
            protocolName = nil
        }

        manualDisconnect = false
        peripheral = target
        if let name = target.name { deviceName = name }
        state = .connecting
        message = nil
        // На macOS запит на з'єднання не має тайм-ауту: підключимось, щойно
        // акумулятор з'явиться в зоні досяжності.
        central.connect(target, options: nil)
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

    // MARK: - Polling

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

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .idle
            reconnect()
        case .poweredOff:
            resetLink()
            isScanning = false
            state = .poweredOff
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        default:
            state = .unknown
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let hint = BMSRegistry.guess(advertised: advertised, name: name)

        // Знайшли збережений пристрій — підключаємось автоматично.
        if peripheral.identifier == savedPeripheralID, state == .idle {
            connect(peripheral)
            return
        }

        guard name != nil || hint != nil else { return }
        let rssi = RSSI.intValue
        guard rssi != 127 else { return } // 127 = RSSI недоступний

        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index].rssi = rssi
        } else {
            devices.append(DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral,
                                            name: name ?? "Без назви", rssi: rssi, hint: hint))
        }
        devices.sort {
            if ($0.hint != nil) != ($1.hint != nil) { return $0.hint != nil }
            return $0.rssi > $1.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        state = .discovering
        message = nil
        savedPeripheralID = peripheral.identifier
        if let name = peripheral.name {
            deviceName = name
            defaults.set(name, forKey: Keys.peripheralName)
        }
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        resetLink()
        state = .idle
        message = "Не вдалося підключитися: \(error?.localizedDescription ?? "невідома помилка")"
        scheduleReconnect(after: 5)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        resetLink()
        if central.state == .poweredOn { state = .idle }
        if !manualDisconnect {
            message = "З'єднання втрачено, перепідключаюсь…"
            scheduleReconnect(after: 2)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
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
