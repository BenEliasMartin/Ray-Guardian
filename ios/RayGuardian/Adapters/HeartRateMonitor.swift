import Combine
import CoreBluetooth
import GuardianCore
@MainActor final class HeartRateMonitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Sensor: Identifiable { let id: UUID, name: String; let peripheral: CBPeripheral }
    @Published var sensors: [Sensor] = []
    @Published var status = "Off"
    @Published var bpm: Int?
    var onMeasurement: ((Int) -> Void)?
    private var scanning = false
    private var central: CBCentralManager?, peripheral: CBPeripheral?
    func scan() { stop(); scanning = true; sensors = []; status = "Starting Bluetooth"; central = CBCentralManager(delegate:self,queue:.main) }
    func connect(_ sensor: Sensor) { central?.stopScan(); peripheral = sensor.peripheral; peripheral?.delegate = self; central?.connect(sensor.peripheral); status = "Connecting \(sensor.name)" }
    func stop() { scanning = false; central?.stopScan(); if let peripheral { central?.cancelPeripheralConnection(peripheral) }; peripheral = nil; bpm = nil; status = "Off" }
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) { Task { @MainActor in
        guard self.scanning,self.central === central else { return }
        if central.state == .poweredOn { self.status = "Scanning heart-rate sensors"; central.scanForPeripherals(withServices:[CBUUID(string:"180D")]) }
        else { self.status = "Bluetooth unavailable or permission denied" }
    } }
    nonisolated func centralManager(_ central: CBCentralManager,didDiscover peripheral: CBPeripheral,advertisementData: [String:Any],rssi RSSI: NSNumber) { Task { @MainActor in
        guard !self.sensors.contains(where:{$0.id == peripheral.identifier}) else { return }; self.sensors.append(Sensor(id:peripheral.identifier,name:peripheral.name ?? "Heart-rate sensor",peripheral:peripheral))
    } }
    nonisolated func centralManager(_ central: CBCentralManager,didConnect peripheral: CBPeripheral) { Task { @MainActor in peripheral.discoverServices([CBUUID(string:"180D")]); self.status = "Discovering heart-rate service" } }
    nonisolated func centralManager(_ central: CBCentralManager,didFailToConnect peripheral: CBPeripheral,error: Error?) { Task { @MainActor in self.status = "Heart-rate connection failed"; self.bpm = nil } }
    nonisolated func centralManager(_ central: CBCentralManager,didDisconnectPeripheral peripheral: CBPeripheral,error: Error?) { Task { @MainActor in self.status = "Heart-rate sensor disconnected"; self.bpm = nil } }
    nonisolated func peripheral(_ peripheral: CBPeripheral,didDiscoverServices error: Error?) { Task { @MainActor in for service in peripheral.services ?? [] where service.uuid == CBUUID(string:"180D") { peripheral.discoverCharacteristics([CBUUID(string:"2A37")],for:service) } } }
    nonisolated func peripheral(_ peripheral: CBPeripheral,didDiscoverCharacteristicsFor service: CBService,error: Error?) { Task { @MainActor in for characteristic in service.characteristics ?? [] where characteristic.uuid == CBUUID(string:"2A37") { peripheral.setNotifyValue(true,for:characteristic); self.status = "Receiving heart-rate measurements" } } }
    nonisolated func peripheral(_ peripheral: CBPeripheral,didUpdateValueFor characteristic: CBCharacteristic,error: Error?) { Task { @MainActor in
        guard peripheral.identifier == self.peripheral?.identifier, error == nil,let bytes = characteristic.value,let bpm = HeartRateMeasurement.decode(bytes) else { return }; self.bpm = bpm; self.onMeasurement?(bpm)
    } }
}
