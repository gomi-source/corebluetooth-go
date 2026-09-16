import Foundation
import CoreBluetooth

/// One instance per CBPeripheral we've ever seen, assigned as that
/// peripheral's `.delegate`. Tracks in-flight operations so the
/// corresponding CBPeripheralDelegate callback can resolve the right
/// pending JSON-RPC call.
final class PeripheralSession: NSObject {
    let peripheral: CBPeripheral
    var onEvent: ((String, Encodable) -> Void)?

    var pendingConnect: ((Result<Void, Error>) -> Void)?
    var pendingDisconnect: ((Result<Void, Error>) -> Void)?
    var pendingDiscoverServices: ((Result<[CBService], Error>) -> Void)?
    var pendingDiscoverCharacteristics: [String: (Result<[CBCharacteristic], Error>) -> Void] = [:] // key: serviceUUID uppercased
    var pendingReads: [String: (Result<Data, Error>) -> Void] = [:] // key: characteristicUUID uppercased
    var pendingWrites: [String: (Result<Void, Error>) -> Void] = [:] // key: characteristicUUID uppercased
    var pendingNotifyToggles: [String: (Result<Void, Error>) -> Void] = [:] // key: characteristicUUID uppercased
    var pendingRSSIReads: [(Result<Int, Error>) -> Void] = []

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    var id: String { peripheral.identifier.uuidString }

    /// Called when the peripheral disconnects (or the process is tearing
    /// down) so no caller is left waiting forever on a completion that will
    /// now never come from CoreBluetooth.
    func failAllPending(with error: Error) {
        pendingDiscoverServices?(.failure(error))
        pendingDiscoverServices = nil

        for (_, cb) in pendingDiscoverCharacteristics { cb(.failure(error)) }
        pendingDiscoverCharacteristics.removeAll()

        for (_, cb) in pendingReads { cb(.failure(error)) }
        pendingReads.removeAll()

        for (_, cb) in pendingWrites { cb(.failure(error)) }
        pendingWrites.removeAll()

        for (_, cb) in pendingNotifyToggles { cb(.failure(error)) }
        pendingNotifyToggles.removeAll()

        for cb in pendingRSSIReads { cb(.failure(error)) }
        pendingRSSIReads.removeAll()
    }

    // MARK: - Actions (called from RPCDispatcher)

    func discoverServices(uuids: [String]?, completion: @escaping (Result<[CBService], Error>) -> Void) {
        pendingDiscoverServices = completion
        peripheral.discoverServices(uuids?.map { CBUUID(string: $0) })
    }

    func discoverCharacteristics(serviceUUID: String, uuids: [String]?, completion: @escaping (Result<[CBCharacteristic], Error>) -> Void) {
        guard let service = findService(serviceUUID) else {
            completion(.failure(BridgeError.serviceNotFound(serviceUUID)))
            return
        }
        pendingDiscoverCharacteristics[serviceUUID.uppercased()] = completion
        peripheral.discoverCharacteristics(uuids?.map { CBUUID(string: $0) }, for: service)
    }

    func readValue(serviceUUID: String, characteristicUUID: String, completion: @escaping (Result<Data, Error>) -> Void) {
        do {
            let characteristic = try findCharacteristic(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)
            pendingReads[characteristicUUID.uppercased()] = completion
            peripheral.readValue(for: characteristic)
        } catch {
            completion(.failure(error))
        }
    }

    func writeValue(serviceUUID: String, characteristicUUID: String, data: Data, withResponse: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let characteristic = try findCharacteristic(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)
            let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
            if withResponse {
                pendingWrites[characteristicUUID.uppercased()] = completion
            }
            peripheral.writeValue(data, for: characteristic, type: type)
            if !withResponse {
                // CoreBluetooth never calls the delegate back for
                // .withoutResponse writes; acknowledge once it's queued.
                completion(.success(()))
            }
        } catch {
            completion(.failure(error))
        }
    }

    func setNotify(serviceUUID: String, characteristicUUID: String, enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let characteristic = try findCharacteristic(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)
            pendingNotifyToggles[characteristicUUID.uppercased()] = completion
            peripheral.setNotifyValue(enabled, for: characteristic)
        } catch {
            completion(.failure(error))
        }
    }

    func readRSSI(completion: @escaping (Result<Int, Error>) -> Void) {
        pendingRSSIReads.append(completion)
        peripheral.readRSSI()
    }

    // MARK: - Lookup helpers

    private func findService(_ uuid: String) -> CBService? {
        peripheral.services?.first { $0.uuid.uuidString.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    private func findCharacteristic(serviceUUID: String, characteristicUUID: String) throws -> CBCharacteristic {
        guard let service = findService(serviceUUID) else {
            throw BridgeError.serviceNotFound(serviceUUID)
        }
        guard let characteristic = service.characteristics?.first(where: {
            $0.uuid.uuidString.caseInsensitiveCompare(characteristicUUID) == .orderedSame
        }) else {
            throw BridgeError.characteristicNotFound(characteristicUUID)
        }
        return characteristic
    }
}

extension PeripheralSession: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        defer { pendingDiscoverServices = nil }
        if let error = error {
            pendingDiscoverServices?(.failure(error))
        } else {
            pendingDiscoverServices?(.success(peripheral.services ?? []))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let key = service.uuid.uuidString.uppercased()
        guard let completion = pendingDiscoverCharacteristics[key] else { return }
        pendingDiscoverCharacteristics[key] = nil
        if let error = error {
            completion(.failure(error))
        } else {
            completion(.success(service.characteristics ?? []))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = characteristic.uuid.uuidString.uppercased()

        // This delegate method fires both for an explicit readValue() call
        // and for an unsolicited notify/indicate push. If we have a pending
        // read for this characteristic, treat it as the read's response;
        // otherwise it's a notification. (If a manual read races with an
        // active notification on the same characteristic, one update can
        // resolve the other's slot - see PROTOCOL.md.)
        if let completion = pendingReads[key] {
            pendingReads[key] = nil
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(characteristic.value ?? Data()))
            }
            return
        }

        guard let serviceUUID = characteristic.service?.uuid.uuidString else { return }
        if let error = error {
            onEvent?("event.error", ErrorEvent(message: "characteristic update error: \(error.localizedDescription)"))
            return
        }
        let event = CharacteristicValueUpdateEvent(
            peripheralId: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristic.uuid.uuidString,
            valueBase64: (characteristic.value ?? Data()).base64EncodedString(),
            isNotification: true
        )
        onEvent?("event.characteristicValueUpdated", event)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = characteristic.uuid.uuidString.uppercased()
        guard let completion = pendingWrites[key] else { return }
        pendingWrites[key] = nil
        if let error = error {
            completion(.failure(error))
        } else {
            completion(.success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let key = characteristic.uuid.uuidString.uppercased()
        guard let completion = pendingNotifyToggles[key] else { return }
        pendingNotifyToggles[key] = nil
        if let error = error {
            completion(.failure(error))
        } else {
            completion(.success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard !pendingRSSIReads.isEmpty else { return }
        let completion = pendingRSSIReads.removeFirst()
        if let error = error {
            completion(.failure(error))
        } else {
            completion(.success(RSSI.intValue))
        }
    }
}
