import Foundation
import CoreBluetooth

/// Translates incoming JSON-RPC requests into calls on BluetoothCentral /
/// PeripheralSession, and forwards CoreBluetooth delegate events out as
/// JSON-RPC notifications broadcast to all connected clients.
final class RPCDispatcher {
    private let central: BluetoothCentral
    private let server: SocketServer

    init(central: BluetoothCentral, server: SocketServer) {
        self.central = central
        self.server = server
        central.onEvent = { [weak self] method, params in
            self?.broadcast(method: method, params: params)
        }
    }

    private func broadcast<T: Encodable>(method: String, params: T) {
        server.broadcast(makeNotificationData(method: method, params: params))
    }

    func handle(data: Data, respond: @escaping (Data) -> Void) {
        let request: IncomingRequest
        do {
            request = try parseIncoming(line: data)
        } catch {
            respond(makeErrorResponseData(id: nil, code: -32700, message: "parse error"))
            return
        }

        func replySuccess<T: Encodable>(_ result: T) {
            respond(makeResponseData(id: request.id, result: result))
        }
        func replyError(_ code: Int, _ message: String) {
            respond(makeErrorResponseData(id: request.id, code: code, message: message))
        }
        func decodeParams<T: Decodable>(_ type: T.Type) -> T? {
            guard let data = request.paramsData else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        switch request.method {
        case "state.get":
            replySuccess(StateResult(state: central.currentStateString))

        case "scan.start":
            let params = decodeParams(ScanStartParams.self) ?? ScanStartParams()
            do {
                try central.startScan(serviceUUIDs: params.serviceUUIDs, allowDuplicates: params.allowDuplicates)
                replySuccess(EmptyResult())
            } catch {
                replyError(1, "\(error)")
            }

        case "scan.stop":
            central.stopScan()
            replySuccess(EmptyResult())

        case "peripheral.connect":
            guard let params = decodeParams(ConnectParams.self) else { replyError(-32602, "invalid params"); return }
            central.connect(peripheralId: params.peripheralId, timeoutMs: params.timeoutMs) { result in
                switch result {
                case .success: replySuccess(EmptyResult())
                case .failure(let error): replyError(2, "\(error)")
                }
            }

        case "peripheral.disconnect":
            guard let params = decodeParams(PeripheralIDParams.self) else { replyError(-32602, "invalid params"); return }
            central.disconnect(peripheralId: params.peripheralId) { result in
                switch result {
                case .success: replySuccess(EmptyResult())
                case .failure(let error): replyError(2, "\(error)")
                }
            }

        case "peripheral.discoverServices":
            guard let params = decodeParams(DiscoverServicesParams.self) else { replyError(-32602, "invalid params"); return }
            do {
                let session = try central.session(for: params.peripheralId)
                session.discoverServices(uuids: params.serviceUUIDs) { result in
                    switch result {
                    case .success(let services):
                        replySuccess(ServiceListResult(services: services.map {
                            ServiceInfo(uuid: $0.uuid.uuidString, isPrimary: $0.isPrimary)
                        }))
                    case .failure(let error):
                        replyError(3, "\(error)")
                    }
                }
            } catch {
                replyError(3, "\(error)")
            }

        case "peripheral.discoverCharacteristics":
            guard let params = decodeParams(DiscoverCharacteristicsParams.self) else { replyError(-32602, "invalid params"); return }
            do {
                let session = try central.session(for: params.peripheralId)
                session.discoverCharacteristics(serviceUUID: params.serviceUUID, uuids: params.characteristicUUIDs) { result in
                    switch result {
                    case .success(let characteristics):
                        let infos = characteristics.map {
                            CharacteristicInfo(
                                uuid: $0.uuid.uuidString,
                                serviceUUID: params.serviceUUID,
                                properties: CharacteristicProperties(from: $0.properties)
                            )
                        }
                        replySuccess(CharacteristicListResult(characteristics: infos))
                    case .failure(let error):
                        replyError(3, "\(error)")
                    }
                }
            } catch {
                replyError(3, "\(error)")
            }

        case "peripheral.readValue":
            guard let params = decodeParams(CharacteristicRefParams.self) else { replyError(-32602, "invalid params"); return }
            do {
                let session = try central.session(for: params.peripheralId)
                session.readValue(serviceUUID: params.serviceUUID, characteristicUUID: params.characteristicUUID) { result in
                    switch result {
                    case .success(let data): replySuccess(ValueResult(valueBase64: data.base64EncodedString()))
                    case .failure(let error): replyError(4, "\(error)")
                    }
                }
            } catch {
                replyError(4, "\(error)")
            }

        case "peripheral.writeValue":
            guard let params = decodeParams(WriteValueParams.self), let data = Data(base64Encoded: params.valueBase64) else {
                replyError(-32602, "invalid params")
                return
            }
            do {
                let session = try central.session(for: params.peripheralId)
                session.writeValue(serviceUUID: params.serviceUUID, characteristicUUID: params.characteristicUUID, data: data, withResponse: params.withResponse) { result in
                    switch result {
                    case .success: replySuccess(EmptyResult())
                    case .failure(let error): replyError(5, "\(error)")
                    }
                }
            } catch {
                replyError(5, "\(error)")
            }

        case "peripheral.setNotifyValue":
            guard let params = decodeParams(SetNotifyParams.self) else { replyError(-32602, "invalid params"); return }
            do {
                let session = try central.session(for: params.peripheralId)
                session.setNotify(serviceUUID: params.serviceUUID, characteristicUUID: params.characteristicUUID, enabled: params.enabled) { result in
                    switch result {
                    case .success: replySuccess(EmptyResult())
                    case .failure(let error): replyError(6, "\(error)")
                    }
                }
            } catch {
                replyError(6, "\(error)")
            }

        case "peripheral.readRSSI":
            guard let params = decodeParams(PeripheralIDParams.self) else { replyError(-32602, "invalid params"); return }
            do {
                let session = try central.session(for: params.peripheralId)
                session.readRSSI { result in
                    switch result {
                    case .success(let rssi): replySuccess(RSSIResult(rssi: rssi))
                    case .failure(let error): replyError(7, "\(error)")
                    }
                }
            } catch {
                replyError(7, "\(error)")
            }

        default:
            replyError(-32601, "method not found: \(request.method)")
        }
    }
}
