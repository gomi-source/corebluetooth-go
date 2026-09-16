import Foundation
import CoreBluetooth

enum BridgeError: Error, CustomStringConvertible {
    case notReady(String)
    case peripheralNotFound(String)
    case serviceNotFound(String)
    case characteristicNotFound(String)
    case operationFailed(String)
    case timeout(String)

    var description: String {
        switch self {
        case .notReady(let m): return m
        case .peripheralNotFound(let m): return "peripheral not found: \(m)"
        case .serviceNotFound(let m): return "service not found: \(m) (call peripheral.discoverServices first)"
        case .characteristicNotFound(let m): return "characteristic not found: \(m) (call peripheral.discoverCharacteristics first)"
        case .operationFailed(let m): return m
        case .timeout(let m): return "timeout: \(m)"
        }
    }
}

/// Owns the single CBCentralManager for the process and everything that
/// hangs off it: scanning, connecting, and the per-peripheral sessions that
/// track in-flight service/characteristic operations.
final class BluetoothCentral: NSObject {
    private var manager: CBCentralManager!
    private let cbQueue = DispatchQueue(label: "corebluetoothd.cbcentral")

    /// All peripherals CoreBluetooth has ever handed us in this process
    /// (via scan discovery), keyed by identifier string. CoreBluetooth
    /// requires the *same* CBPeripheral instance be reused for connect/
    /// discover/read/write, so this cache is required, not just convenient.
    private var knownPeripherals: [String: CBPeripheral] = [:]
    private var sessions: [String: PeripheralSession] = [:]

    /// method name + Encodable params for a CoreBluetooth delegate event,
    /// forwarded to the RPC layer to broadcast as a JSON-RPC notification.
    var onEvent: ((String, Encodable) -> Void)?

    /// CBCentralManager starts in `.unknown` and only reports its real
    /// state asynchronously via `centralManagerDidUpdateState`. This fires
    /// exactly once, the first time that happens, so main.swift can block
    /// briefly at startup instead of racing the first `state.get` against
    /// CoreBluetooth's own initialization.
    private var hasKnownState = false
    var onFirstState: (() -> Void)?

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: cbQueue, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    // MARK: - State

    var currentStateString: String {
        Self.stateString(manager.state)
    }

    static func stateString(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Scanning

    func startScan(serviceUUIDs: [String]?, allowDuplicates: Bool?) throws {
        guard manager.state == .poweredOn else {
            throw BridgeError.notReady("bluetooth is not powered on (state: \(currentStateString))")
        }
        let uuids = serviceUUIDs?.map { CBUUID(string: $0) }
        var options: [String: Any] = [:]
        if let allowDuplicates = allowDuplicates {
            options[CBCentralManagerScanOptionAllowDuplicatesKey] = allowDuplicates
        }
        manager.scanForPeripherals(withServices: uuids, options: options)
    }

    func stopScan() {
        manager.stopScan()
    }

    // MARK: - Connect / Disconnect

    func connect(peripheralId: String, timeoutMs: Int?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let peripheral = knownPeripherals[peripheralId] else {
            completion(.failure(BridgeError.peripheralNotFound(peripheralId)))
            return
        }
        let session = sessionFor(peripheral)
        session.pendingConnect = completion
        if let timeoutMs = timeoutMs, timeoutMs > 0 {
            let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
            cbQueue.asyncAfter(deadline: deadline) { [weak self, weak session] in
                guard let self = self, let session = session, let pending = session.pendingConnect else { return }
                session.pendingConnect = nil
                self.manager.cancelPeripheralConnection(peripheral)
                pending(.failure(BridgeError.timeout("connect timed out")))
            }
        }
        manager.connect(peripheral, options: nil)
    }

    func disconnect(peripheralId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let peripheral = knownPeripherals[peripheralId] else {
            completion(.failure(BridgeError.peripheralNotFound(peripheralId)))
            return
        }
        let session = sessionFor(peripheral)
        session.pendingDisconnect = completion
        manager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Session lookup

    private func sessionFor(_ peripheral: CBPeripheral) -> PeripheralSession {
        let key = peripheral.identifier.uuidString
        if let existing = sessions[key] { return existing }
        let session = PeripheralSession(peripheral: peripheral)
        session.onEvent = { [weak self] method, params in
            self?.onEvent?(method, params)
        }
        peripheral.delegate = session
        sessions[key] = session
        return session
    }

    func session(for peripheralId: String) throws -> PeripheralSession {
        guard let peripheral = knownPeripherals[peripheralId] else {
            throw BridgeError.peripheralNotFound(peripheralId)
        }
        return sessionFor(peripheral)
    }
}

extension BluetoothCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if !hasKnownState {
            hasKnownState = true
            onFirstState?()
            onFirstState = nil
        }
        onEvent?("event.stateChanged", StateResult(state: currentStateString))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        knownPeripherals[id] = peripheral
        let adv = AdvertisementData(from: advertisementData)
        let event = DiscoveredPeripheralEvent(
            peripheralId: id,
            name: peripheral.name,
            rssi: RSSI.intValue,
            advertisementData: adv,
            isConnectable: adv.isConnectable
        )
        onEvent?("event.peripheralDiscovered", event)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        let session = sessionFor(peripheral)
        onEvent?("event.peripheralConnected", ConnectionEvent(peripheralId: id))
        session.pendingConnect?(.success(()))
        session.pendingConnect = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        let session = sessionFor(peripheral)
        let message = error?.localizedDescription ?? "unknown error"
        onEvent?("event.peripheralConnectFailed", ConnectFailedEvent(peripheralId: id, errorMessage: message))
        session.pendingConnect?(.failure(BridgeError.operationFailed(message)))
        session.pendingConnect = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        let session = sessionFor(peripheral)
        onEvent?("event.peripheralDisconnected", DisconnectEvent(peripheralId: id, errorMessage: error?.localizedDescription))
        session.pendingDisconnect?(.success(()))
        session.pendingDisconnect = nil
        session.failAllPending(with: BridgeError.operationFailed("peripheral disconnected"))
    }
}
