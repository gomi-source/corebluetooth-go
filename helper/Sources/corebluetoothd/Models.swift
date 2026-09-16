import Foundation
import CoreBluetooth

// Wire-format types for the JSON-RPC protocol spoken over the Unix domain
// socket. These are kept intentionally flat and string/base64-based so they
// map cleanly onto Go's encoding/json without any custom marshaling on that
// side. See ../../PROTOCOL.md for the full method/event reference.

typealias PeripheralID = String // CBPeripheral.identifier.uuidString

// MARK: - Request params

struct ScanStartParams: Codable {
    var serviceUUIDs: [String]? = nil
    var allowDuplicates: Bool? = nil
}

struct PeripheralIDParams: Codable {
    var peripheralId: PeripheralID
}

struct ConnectParams: Codable {
    var peripheralId: PeripheralID
    var timeoutMs: Int? = nil
}

struct DiscoverServicesParams: Codable {
    var peripheralId: PeripheralID
    var serviceUUIDs: [String]? = nil
}

struct DiscoverCharacteristicsParams: Codable {
    var peripheralId: PeripheralID
    var serviceUUID: String
    var characteristicUUIDs: [String]? = nil
}

struct CharacteristicRefParams: Codable {
    var peripheralId: PeripheralID
    var serviceUUID: String
    var characteristicUUID: String
}

struct WriteValueParams: Codable {
    var peripheralId: PeripheralID
    var serviceUUID: String
    var characteristicUUID: String
    var valueBase64: String
    var withResponse: Bool
}

struct SetNotifyParams: Codable {
    var peripheralId: PeripheralID
    var serviceUUID: String
    var characteristicUUID: String
    var enabled: Bool
}

// MARK: - Results

struct EmptyResult: Codable {}

struct StateResult: Codable {
    var state: String
}

struct ValueResult: Codable {
    var valueBase64: String
}

struct RSSIResult: Codable {
    var rssi: Int
}

struct ServiceInfo: Codable {
    var uuid: String
    var isPrimary: Bool
}

struct ServiceListResult: Codable {
    var services: [ServiceInfo]
}

struct CharacteristicProperties: Codable {
    var broadcast: Bool
    var read: Bool
    var writeWithoutResponse: Bool
    var write: Bool
    var notify: Bool
    var indicate: Bool
    var authenticatedSignedWrites: Bool
    var extendedProperties: Bool
    var notifyEncryptionRequired: Bool
    var indicateEncryptionRequired: Bool

    init(from p: CBCharacteristicProperties) {
        broadcast = p.contains(.broadcast)
        read = p.contains(.read)
        writeWithoutResponse = p.contains(.writeWithoutResponse)
        write = p.contains(.write)
        notify = p.contains(.notify)
        indicate = p.contains(.indicate)
        authenticatedSignedWrites = p.contains(.authenticatedSignedWrites)
        extendedProperties = p.contains(.extendedProperties)
        notifyEncryptionRequired = p.contains(.notifyEncryptionRequired)
        indicateEncryptionRequired = p.contains(.indicateEncryptionRequired)
    }
}

struct CharacteristicInfo: Codable {
    var uuid: String
    var serviceUUID: String
    var properties: CharacteristicProperties
}

struct CharacteristicListResult: Codable {
    var characteristics: [CharacteristicInfo]
}

// MARK: - Advertisement data

struct AdvertisementData: Codable {
    var localName: String? = nil
    var manufacturerDataBase64: String? = nil
    var serviceUUIDs: [String]? = nil
    var serviceData: [String: String]? = nil
    var txPowerLevel: Int? = nil
    var isConnectable: Bool? = nil
    var overflowServiceUUIDs: [String]? = nil
    var solicitedServiceUUIDs: [String]? = nil
}

extension AdvertisementData {
    init(from raw: [String: Any]) {
        self.localName = raw[CBAdvertisementDataLocalNameKey] as? String

        if let mfgData = raw[CBAdvertisementDataManufacturerDataKey] as? Data {
            self.manufacturerDataBase64 = mfgData.base64EncodedString()
        }

        if let uuids = raw[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            self.serviceUUIDs = uuids.map { $0.uuidString }
        }

        if let sd = raw[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            var out: [String: String] = [:]
            for (uuid, data) in sd {
                out[uuid.uuidString] = data.base64EncodedString()
            }
            self.serviceData = out
        }

        self.txPowerLevel = (raw[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        self.isConnectable = (raw[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue

        if let ov = raw[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            self.overflowServiceUUIDs = ov.map { $0.uuidString }
        }

        if let sol = raw[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] {
            self.solicitedServiceUUIDs = sol.map { $0.uuidString }
        }
    }
}

// MARK: - Events

struct DiscoveredPeripheralEvent: Codable {
    var peripheralId: PeripheralID
    var name: String?
    var rssi: Int
    var advertisementData: AdvertisementData
    var isConnectable: Bool?
}

struct ConnectionEvent: Codable {
    var peripheralId: PeripheralID
}

struct ConnectFailedEvent: Codable {
    var peripheralId: PeripheralID
    var errorMessage: String
}

struct DisconnectEvent: Codable {
    var peripheralId: PeripheralID
    var errorMessage: String?
}

struct CharacteristicValueUpdateEvent: Codable {
    var peripheralId: PeripheralID
    var serviceUUID: String
    var characteristicUUID: String
    var valueBase64: String
    var isNotification: Bool
}

struct ErrorEvent: Codable {
    var message: String
}
