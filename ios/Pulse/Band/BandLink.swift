import Foundation
import CoreBluetooth
import PulseCore

// The "wire" to a band: bytes out, bytes in. Nothing in this file understands the protocol;
// that is PulseCore's job (BandSession), which is tested without hardware.
//
// BluetoothBandLink is the only implementation (CoreBluetooth). The simulated band that used to
// live here is gone: it exists only in PulseCore's unit tests now.

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
    /// A line for the sync log (services found, subscriptions, MTU). No effect on the sync.
    case note(String)
    /// `nil` = we disconnected on purpose.
    case disconnected(String?)
}

/// Events are delivered on the link's own serial queue, NOT the main thread: packets are parsed
/// there, so a big download never makes the screens stutter. Methods may be called from any thread.
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
final class BluetoothBandLink: NSObject, BandLink, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    var onEvent: ((BandLinkEvent) -> Void)?
    /// Every CoreBluetooth callback and every state change of this class happens on this queue.
    let queue = DispatchQueue(label: "dev.pulse.ble", qos: .userInitiated)

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
        let created = CBCentralManager(delegate: self, queue: queue)
        central = created
        return created
    }

    func startScanning() {
        queue.async { [self] in
            wantsScan = true
            let central = manager()
            if central.state == .poweredOn { scan(central) }
        }
    }

    func stopScanning() {
        queue.async { [self] in
            wantsScan = false
            if central?.state == .poweredOn { central?.stopScan() }
        }
    }

    func connect(to id: UUID) {
        queue.async { [self] in
            wantsConnection = id
            let central = manager()
            if central.state == .poweredOn { connectNow(central) }
        }
    }

    func disconnect() {
        queue.async { [self] in
            wantsConnection = nil
            guard let current, let central else { return }
            disconnectingOnPurpose = true
            central.cancelPeripheralConnection(current)
        }
    }

    func write(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard let current, let commandCharacteristic else { return }
            current.writeValue(Data(bytes), for: commandCharacteristic, type: .withResponse)
        }
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
        let all = (peripheral.services ?? []).map { $0.uuid.uuidString.lowercased() }.joined(separator: ", ")
        onEvent?(.note("Services: \(all)"))
        for service in bandServices { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let notifying = [Whoop.cmdFromStrapUUID, Whoop.eventsUUID, Whoop.dataUUID]
        for characteristic in service.characteristics ?? [] {
            let uuid = characteristic.uuid.uuidString.lowercased()
            let props = characteristic.properties
            let flags = [props.contains(.read) ? "read" : nil, props.contains(.write) ? "write" : nil,
                         props.contains(.writeWithoutResponse) ? "writeNoResp" : nil,
                         props.contains(.notify) ? "notify" : nil, props.contains(.indicate) ? "indicate" : nil]
                .compactMap { $0 }.joined(separator: "/")
            onEvent?(.note("Characteristic \(uuid) [\(flags)]\(notifying.contains(uuid) ? " -> subscribing" : "")\(uuid == Whoop.cmdToStrapUUID ? " -> command channel" : "")"))
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
        onEvent?(.note("Notifications \(characteristic.isNotifying ? "on" : "off") for \(characteristic.uuid.uuidString.lowercased())"))
        notifyPending -= 1
        if notifyPending == 0 && commandCharacteristic != nil {
            // How big one notification / write can be on this connection. History frames are often
            // bigger than this, so they arrive split across notifications (the reassembler joins them).
            let noResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
            let withResponse = peripheral.maximumWriteValueLength(for: .withResponse)
            onEvent?(.note("MTU: \(noResponse) bytes per packet (ATT MTU ≈ \(noResponse + 3)), \(withResponse) bytes per write with response"))
            onEvent?(.connected)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        onEvent?(.notification(characteristic: characteristic.uuid.uuidString.lowercased(), bytes: [UInt8](data)))
    }
}
