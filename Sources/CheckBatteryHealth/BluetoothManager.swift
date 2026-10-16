import Combine
import CoreBluetooth
import Foundation

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var hint: String?
}

/// Керує Bluetooth і списком підключених акумуляторів (кожен — `BatteryLink`).
/// Усі колбеки CoreBluetooth приходять на головну чергу, тому @Published-властивості
/// змінюються безпечно.
final class BluetoothManager: NSObject, ObservableObject {
    enum BluetoothState: Equatable {
        case unknown, poweredOff, unauthorized, unsupported, poweredOn
    }

    @Published private(set) var bluetoothState: BluetoothState = .unknown
    @Published private(set) var isScanning = false
    /// Пошук завершився (а не ще не запускався) — щоб показати «нічого не знайдено».
    @Published private(set) var scanFinished = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var links: [BatteryLink] = []

    @Published var pollInterval: Double {
        didSet {
            defaults.set(pollInterval, forKey: Keys.pollInterval)
            links.forEach { $0.pollInterval = pollInterval }
        }
    }

    /// Показувати в рядку меню, скільки часу залишилось (до розряду або заряду).
    @Published var showTimeInMenuBar: Bool {
        didSet { defaults.set(showTimeInMenuBar, forKey: Keys.showTimeInMenuBar) }
    }

    /// Показувати в рядку меню потужність заряду / розряду.
    @Published var showPowerInMenuBar: Bool {
        didSet { defaults.set(showPowerInMenuBar, forKey: Keys.showPowerInMenuBar) }
    }

    /// Поріг попередження про низький заряд, %. 0 — вимкнено.
    @Published var lowBatteryThreshold: Int {
        didSet {
            defaults.set(lowBatteryThreshold, forKey: Keys.lowBatteryThreshold)
            warnedLowBattery.removeAll()
        }
    }

    var isPoweredOn: Bool { bluetoothState == .poweredOn }

    private struct SavedDevice: Codable {
        let id: UUID
        var name: String
    }

    private enum Keys {
        static let savedDevices = "savedDevices"
        static let pollInterval = "pollInterval"
        static let showTimeInMenuBar = "showTimeInMenuBar"
        static let showPowerInMenuBar = "showPowerInMenuBar"
        static let lowBatteryThreshold = "lowBatteryThreshold"
        // Старий формат — один пристрій.
        static let legacyPeripheralID = "savedPeripheralID"
        static let legacyPeripheralName = "savedPeripheralName"
    }

    private let defaults = UserDefaults.standard
    private var central: CBCentralManager!
    private var scanStopWorkItem: DispatchWorkItem?
    private var linkObservers: [UUID: [AnyCancellable]] = [:]
    /// Акумулятори, про які вже попередили (до наступного підйому заряду).
    private var warnedLowBattery: Set<UUID> = []

    override init() {
        let storedInterval = UserDefaults.standard.double(forKey: Keys.pollInterval)
        pollInterval = storedInterval > 0 ? storedInterval : 5
        showTimeInMenuBar = UserDefaults.standard.bool(forKey: Keys.showTimeInMenuBar)
        showPowerInMenuBar = UserDefaults.standard.bool(forKey: Keys.showPowerInMenuBar)
        lowBatteryThreshold = UserDefaults.standard.object(forKey: Keys.lowBatteryThreshold)
            as? Int ?? 20
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        loadSavedDevices().forEach { addLink(id: $0.id, name: $0.name) }
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        isScanning = true
        scanFinished = false
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
        if isScanning { scanFinished = true }
        isScanning = false
    }

    func isAdded(_ device: DiscoveredDevice) -> Bool {
        links.contains { $0.id == device.id }
    }

    /// Додати акумулятор до списку і підключитися. Якщо вже доданий — перепідключитися.
    func add(_ device: DiscoveredDevice) {
        let link = links.first { $0.id == device.id }
            ?? addLink(id: device.id, name: device.name)
        saveDevices()
        if link.state == .idle { link.connect(device.peripheral) }
    }

    func disconnect(_ link: BatteryLink) {
        link.disconnect()
    }

    func reconnect(_ link: BatteryLink) {
        guard central.state == .poweredOn else { return }
        if let peripheral = link.peripheral {
            link.connect(peripheral)
        } else if let known = central.retrievePeripherals(withIdentifiers: [link.id]).first {
            link.connect(known)
        } else {
            link.setMessage("Шукаю пристрій…")
            if !isScanning { startScan() }
        }
    }

    func forget(_ link: BatteryLink) {
        link.tearDown()
        linkObservers[link.id] = nil
        warnedLowBattery.remove(link.id)
        links.removeAll { $0.id == link.id }
        saveDevices()
    }

    // MARK: - Links

    @discardableResult
    private func addLink(id: UUID, name: String) -> BatteryLink {
        let link = BatteryLink(id: id, name: name, central: central, pollInterval: pollInterval)
        link.onNameChange = { [weak self] _ in self?.saveDevices() }
        // Пересилаємо зміни акумулятора, щоб оновлювались рядок меню і вікно.
        linkObservers[id] = [
            link.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            },
            link.$reading.sink { [weak self, weak link] reading in
                guard let self, let link else { return }
                self.checkLowBattery(link, reading)
            },
        ]
        links.append(link)
        return link
    }

    /// Заряд нижче порогу і акумулятор не заряджається.
    func isLow(_ reading: BatteryReading) -> Bool {
        guard lowBatteryThreshold > 0, let soc = reading.soc else { return false }
        return soc < Double(lowBatteryThreshold) && !reading.isCharging
    }

    /// Одне сповіщення на кожне падіння нижче порогу; знову — після підйому
    /// заряду на 3% вище порогу (щоб не спамити на межі).
    private func checkLowBattery(_ link: BatteryLink, _ reading: BatteryReading) {
        guard let soc = reading.soc else { return }
        if isLow(reading) {
            if warnedLowBattery.insert(link.id).inserted {
                Notifier.lowBattery(id: link.id, name: link.name, reading: reading)
            }
        } else if soc >= Double(lowBatteryThreshold + 3) {
            warnedLowBattery.remove(link.id)
        }
    }

    private func link(for peripheral: CBPeripheral) -> BatteryLink? {
        links.first { $0.id == peripheral.identifier }
    }

    private func reconnectAll() {
        links.filter { $0.state == .idle && !$0.manualDisconnect }.forEach(reconnect)
    }

    // MARK: - Persistence

    private func loadSavedDevices() -> [SavedDevice] {
        if let data = defaults.data(forKey: Keys.savedDevices),
           let saved = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            return saved
        }
        // Перенесення зі старої версії, де зберігався лише один пристрій.
        guard let legacy = defaults.string(forKey: Keys.legacyPeripheralID)
            .flatMap(UUID.init(uuidString:)) else { return [] }
        let name = defaults.string(forKey: Keys.legacyPeripheralName) ?? "Акумулятор LiFePO4"
        defaults.removeObject(forKey: Keys.legacyPeripheralID)
        defaults.removeObject(forKey: Keys.legacyPeripheralName)
        let saved = [SavedDevice(id: legacy, name: name)]
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Keys.savedDevices)
        }
        return saved
    }

    private func saveDevices() {
        let saved = links.map { SavedDevice(id: $0.id, name: $0.name) }
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Keys.savedDevices)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = .poweredOn
            reconnectAll()
        case .poweredOff:
            links.forEach { $0.bluetoothPoweredOff() }
            isScanning = false
            bluetoothState = .poweredOff
        case .unauthorized:
            bluetoothState = .unauthorized
        case .unsupported:
            bluetoothState = .unsupported
        default:
            bluetoothState = .unknown
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let hint = BMSRegistry.guess(advertised: advertised, name: name)

        // Знайшли збережений, але не підключений пристрій — підключаємось автоматично.
        if let link = link(for: peripheral), link.state == .idle, !link.manualDisconnect {
            link.connect(peripheral)
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
        link(for: peripheral)?.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        link(for: peripheral)?.didFailToConnect(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        link(for: peripheral)?.didDisconnect()
    }
}
