import Foundation
import CoreBluetooth
import PulseCore

// The "wire" to a band: bytes out, bytes in. Nothing in this file understands the protocol;
// that is PulseCore's job (BandSession), which is tested without hardware.
//
// Two implementations:
//   BluetoothBandLink  - the real thing (CoreBluetooth). ⚠ Never run against a real band yet.
//   SimulatedBandLink  - PulseCore's SimulatedBand, so the whole pipeline can be tried in the
//                        simulator and before the band arrives.

/// A band seen while scanning.
struct DiscoveredBand: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Signal strength in dBm (closer to 0 = nearer). Roughly: above -60 is close, below -80 is far.
    let signal: Int

    var distanceWord: String {
        if signal >= -60 { return "Very close" }
        if signal >= -80 { return "Nearby" }
        return "Far away"
    }
}

enum BandAvailability: Equatable {
    case ready
    case poweredOff
    case notAllowed        // the user said no to the Bluetooth permission
    case unsupported       // e.g. the iOS simulator has no Bluetooth
}

enum BandLinkEvent {
    case availability(BandAvailability)
    case discovered(DiscoveredBand)
    /// Connected, characteristics found, notifications switched on: ready for commands.
    case connected
    case notification(characteristic: String, bytes: [UInt8])
    /// `nil` = we disconnected on purpose.
    case disconnected(String?)
}

/// Events are always delivered on the main thread.
protocol BandLink: AnyObject {
    var onEvent: ((BandLinkEvent) -> Void)? { get set }
    func startScanning()
    func stopScanning()
    func connect(to id: UUID)
    func disconnect()
    /// Writes one command frame to the band.
    func write(_ bytes: [UInt8])
}

// MARK: - Real Bluetooth

/// CoreBluetooth implementation.
///
/// Things that are still guesses until a real band is here (see re-toolkit/docs/PROTOCOL.md):
/// - Whether the band puts its service UUID in its advertisement. So we scan for everything and
///   keep devices whose name contains "WHOOP" or that advertise a service starting with 6108.
/// - Which service UUID it uses (…0000 or …0001). We accept any service starting with 6108.
/// - Whether iOS shows a pairing prompt (bonding). If the band requires it, iOS asks by itself.
/// Not done yet: reconnecting in the background (state restoration).
final class BluetoothBandLink: NSObject, BandLink, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onEvent: ((BandLinkEvent) -> Void)?

    private var central: CBCentralManager?
    private var seen: [UUID: CBPeripheral] = [:]
    private var current: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var notifyPending = 0
    private var wantsScan = false
    private var wantsConnection: UUID?
    private var disconnectingOnPurpose = false

    /// Creating the manager is what makes iOS show the Bluetooth permission prompt, so it is
    /// created only when the user actually starts pairing or syncing.
    private func manager() -> CBCentralManager {
        if let central { return central }
        let created = CBCentralManager(delegate: self, queue: .main)
        central = created
        return created
    }

    func startScanning() {
        wantsScan = true
        let central = manager()
        if central.state == .poweredOn { scan(central) }
    }

    func stopScanning() {
        wantsScan = false
        if central?.state == .poweredOn { central?.stopScan() }
    }

    func connect(to id: UUID) {
        wantsConnection = id
        let central = manager()
        if central.state == .poweredOn { connectNow(central) }
    }

    func disconnect() {
        wantsConnection = nil
        guard let current, let central else { return }
        disconnectingOnPurpose = true
        central.cancelPeripheralConnection(current)
    }

    func write(_ bytes: [UInt8]) {
        guard let current, let commandCharacteristic else { return }
        current.writeValue(Data(bytes), for: commandCharacteristic, type: .withResponse)
    }

    private func scan(_ central: CBCentralManager) {
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func connectNow(_ central: CBCentralManager) {
        guard let id = wantsConnection else { return }
        // A band we paired before can be found again by its identifier, without scanning.
        guard let peripheral = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            onEvent?(.disconnected("Your band was not found. Bring it close and try again."))
            return
        }
        wantsConnection = nil
        seen[id] = peripheral
        current = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onEvent?(.availability(.ready))
            if wantsScan { scan(central) }
            connectNow(central)
        case .poweredOff:
            onEvent?(.availability(.poweredOff))
        case .unauthorized:
            onEvent?(.availability(.notAllowed))
        case .unsupported:
            onEvent?(.availability(.unsupported))
        default:
            break       // .unknown / .resetting: iOS will call again
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasBandService = services.contains { $0.uuidString.lowercased().hasPrefix(Whoop.uuidPrefix) }
        guard name.uppercased().contains("WHOOP") || hasBandService else { return }
        seen[peripheral.identifier] = peripheral
        onEvent?(.discovered(DiscoveredBand(id: peripheral.identifier, name: name.isEmpty ? "WHOOP band" : name,
                                            signal: RSSI.intValue)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        commandCharacteristic = nil
        notifyPending = 0
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        current = nil
        onEvent?(.disconnected(error?.localizedDescription ?? "Could not connect to the band."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let onPurpose = disconnectingOnPurpose
        disconnectingOnPurpose = false
        current = nil
        commandCharacteristic = nil
        onEvent?(.disconnected(onPurpose ? nil : (error?.localizedDescription ?? "The band disconnected.")))
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let bandServices = (peripheral.services ?? []).filter {
            $0.uuid.uuidString.lowercased().hasPrefix(Whoop.uuidPrefix)
        }
        guard !bandServices.isEmpty else {
            onEvent?(.disconnected("This device doesn't offer the band's data service."))
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        for service in bandServices { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let notifying = [Whoop.cmdFromStrapUUID, Whoop.eventsUUID, Whoop.dataUUID]
        for characteristic in service.characteristics ?? [] {
            let uuid = characteristic.uuid.uuidString.lowercased()
            if uuid == Whoop.cmdToStrapUUID { commandCharacteristic = characteristic }
            if notifying.contains(uuid) {
                notifyPending += 1
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if commandCharacteristic == nil && notifyPending == 0 {
            onEvent?(.disconnected("The band's command channel was not found."))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            onEvent?(.disconnected("The band refused notifications: \(error.localizedDescription)"))
            return
        }
        notifyPending -= 1
        if notifyPending == 0 && commandCharacteristic != nil { onEvent?(.connected) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        onEvent?(.notification(characteristic: characteristic.uuid.uuidString.lowercased(), bytes: [UInt8](data)))
    }
}

// MARK: - Simulated band

/// A pretend band, for the simulator and for trying the app before the real band arrives.
/// It "replays" minutes handed to it as if the band had recorded them, byte for byte through the
/// same protocol code as the real band.
final class SimulatedBandLink: BandLink {
    /// Fixed identifier, so the app can tell the simulated band from a real one.
    static let bandID = UUID(uuidString: "00000000-0000-4000-8000-0000000051AB")!
    static let bandName = "Simulated band"

    var onEvent: ((BandLinkEvent) -> Void)?

    /// Gives the minutes the band should have "recorded" (the last two days of stored data).
    private let recordedMinutes: () -> [MinuteSample]
    private var band: SimulatedBand?
    private var outbox: AsyncStream<[SimulatedBand.Notification]>.Continuation?
    private var pump: Task<Void, Never>?

    init(recordedMinutes: @escaping () -> [MinuteSample]) {
        self.recordedMinutes = recordedMinutes
    }

    func startScanning() {
        onEvent?(.availability(.ready))
        // A short pause, so the "Searching" state is visible like with a real band.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.onEvent?(.discovered(DiscoveredBand(id: Self.bandID, name: Self.bandName, signal: -48)))
        }
    }

    func stopScanning() {}

    func connect(to id: UUID) {
        let samples = SimulatedBand.samples(from: recordedMinutes())
        band = SimulatedBand(samples: samples, batchSize: 3600, mtuPayload: 244,
                             clock: UInt32(Date().timeIntervalSince1970))
        // One consumer delivers notifications in order, yielding often so the screen stays responsive.
        let (stream, continuation) = AsyncStream<[SimulatedBand.Notification]>.makeStream()
        outbox = continuation
        pump = Task { @MainActor [weak self] in
            for await batch in stream {
                for (index, notification) in batch.enumerated() {
                    guard let self, !Task.isCancelled else { return }
                    self.onEvent?(.notification(characteristic: notification.characteristic, bytes: notification.bytes))
                    if index % 100 == 99 { await Task.yield() }
                }
            }
        }
        onEvent?(.connected)
    }

    func disconnect() {
        pump?.cancel()
        outbox?.finish()
        band = nil
        onEvent?(.disconnected(nil))
    }

    func write(_ bytes: [UInt8]) {
        guard var simulated = band else { return }
        let notifications = simulated.receive(write: bytes)
        band = simulated
        outbox?.yield(notifications)
    }
}
