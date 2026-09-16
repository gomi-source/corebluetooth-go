# corebluetoothd wire protocol

Transport: a Unix domain socket (path chosen by the client, passed to the
helper as `--socket`). Framing: one JSON object per line (`\n`-terminated,
UTF-8). Messages are JSON-RPC 2.0 shaped:

- **Request** (client -> server): `{"jsonrpc":"2.0","id":<int>,"method":"...","params":{...}}`
- **Response** (server -> client): `{"jsonrpc":"2.0","id":<int>,"result":{...}}` or
  `{"jsonrpc":"2.0","id":<int>,"error":{"code":<int>,"message":"..."}}`
- **Notification** (server -> client, unsolicited): `{"jsonrpc":"2.0","method":"event....","params":{...}}` (no `id`)

Requests and notifications are interleaved on the same connection, so a
client must always inspect an incoming line for a `method` field (with no
`id`) vs. an `id` field before deciding how to route it. See
`ble/rpc.go` for a reference implementation.

Binary values (characteristic values, manufacturer/service advertisement
data) are base64-encoded strings on the wire.

## Startup handshake

1. The client spawns the helper: `corebluetoothd --socket <path> [--parent-pid <pid>]`.
2. The helper binds and listens on `<path>`, then prints `READY <path>\n`
   to stdout (unbuffered) and keeps running.
3. The client connects to `<path>` once it has seen the `READY` line (a
   short dial-retry loop is still recommended as a defense-in-depth
   fallback).
4. If `--parent-pid` was given, the helper polls every 2s via `kill(pid, 0)`
   and exits if that process is gone, so a crashed client never leaves an
   orphaned helper holding the Bluetooth radio.
5. `SIGTERM`/`SIGINT` make the helper clean up its socket file and exit.

## Methods

| Method | Params | Result | Notes |
|---|---|---|---|
| `state.get` | *(none)* | `{state}` | `state` is one of `poweredOn`, `poweredOff`, `unauthorized`, `unsupported`, `resetting`, `unknown`. |
| `scan.start` | `{serviceUUIDs?, allowDuplicates?}` | `{}` | Fails if the adapter isn't `poweredOn`. Results stream via `event.peripheralDiscovered`. |
| `scan.stop` | *(none)* | `{}` | |
| `peripheral.connect` | `{peripheralId, timeoutMs?}` | `{}` | Blocks until CoreBluetooth reports connected/failed (or `timeoutMs` elapses). `peripheralId` must come from a prior `event.peripheralDiscovered`. |
| `peripheral.disconnect` | `{peripheralId}` | `{}` | Blocks until disconnected. |
| `peripheral.discoverServices` | `{peripheralId, serviceUUIDs?}` | `{services: [{uuid, isPrimary}]}` | Must be called (and awaited) before `discoverCharacteristics`. |
| `peripheral.discoverCharacteristics` | `{peripheralId, serviceUUID, characteristicUUIDs?}` | `{characteristics: [{uuid, serviceUUID, properties}]}` | Must be called (and awaited) before read/write/setNotifyValue on that service's characteristics. |
| `peripheral.readValue` | `{peripheralId, serviceUUID, characteristicUUID}` | `{valueBase64}` | |
| `peripheral.writeValue` | `{peripheralId, serviceUUID, characteristicUUID, valueBase64, withResponse}` | `{}` | When `withResponse` is `false`, the result returns as soon as the write is queued (CoreBluetooth never calls back for write-without-response). |
| `peripheral.setNotifyValue` | `{peripheralId, serviceUUID, characteristicUUID, enabled}` | `{}` | Once enabled, updates arrive via `event.characteristicValueUpdated`. |
| `peripheral.readRSSI` | `{peripheralId}` | `{rssi}` | |

`properties` is `{broadcast, read, writeWithoutResponse, write, notify,
indicate, authenticatedSignedWrites, extendedProperties,
notifyEncryptionRequired, indicateEncryptionRequired}` (all booleans),
mirroring `CBCharacteristicProperties`.

### Errors

| Code | Meaning |
|---|---|
| `-32700` | Parse error (malformed JSON) |
| `-32601` | Unknown method |
| `-32602` | Invalid/missing params |
| `1` | Scan could not start (e.g. adapter not powered on) |
| `2` | Connect/disconnect failed |
| `3` | Service/characteristic discovery failed |
| `4` | Read failed |
| `5` | Write failed |
| `6` | Notify toggle failed |
| `7` | RSSI read failed |

## Events (notifications)

| Method | Params | Fired when |
|---|---|---|
| `event.stateChanged` | `{state}` | The adapter's `CBManagerState` changes. |
| `event.peripheralDiscovered` | `{peripheralId, name?, rssi, advertisementData, isConnectable?}` | A scan is active and an advertisement is seen. |
| `event.peripheralConnected` | `{peripheralId}` | Informational; `peripheral.connect`'s response already carries this. |
| `event.peripheralConnectFailed` | `{peripheralId, errorMessage}` | Informational; `peripheral.connect`'s response already carries this. |
| `event.peripheralDisconnected` | `{peripheralId, errorMessage?}` | Any disconnect, requested or not. `errorMessage` is absent for a clean, requested disconnect. |
| `event.characteristicValueUpdated` | `{peripheralId, serviceUUID, characteristicUUID, valueBase64, isNotification}` | A characteristic subscribed via `setNotifyValue` pushes a new value. |
| `event.error` | `{message}` | An async error not tied to a specific pending request. |

`advertisementData` is `{localName?, manufacturerDataBase64?,
serviceUUIDs?, serviceData?, txPowerLevel?, isConnectable?,
overflowServiceUUIDs?, solicitedServiceUUIDs?}`, mirroring the
`CBAdvertisementData*` keys.

## Known simplifications (v1)

- **One CBCentralManager per process, central role only.** No peripheral
  (advertiser/GATT server) role.
- **`didUpdateValueFor` disambiguation.** CoreBluetooth uses the same
  delegate callback for both "response to an explicit `readValue`" and
  "unsolicited notify/indicate push". The helper treats an update as the
  former if a read is pending for that characteristic, otherwise as the
  latter. If you call `peripheral.readValue` on a characteristic that also
  has notifications enabled, a notification that lands first can be
  consumed as the read's response (and vice versa). Avoid overlapping
  manual reads with active notifications on the same characteristic if you
  need to tell them apart.
- **Ordering requirement.** `discoverServices` must complete before
  `discoverCharacteristics` for that peripheral, and `discoverCharacteristics`
  for a given service must complete before read/write/setNotifyValue on its
  characteristics - this mirrors CoreBluetooth itself, which only populates
  `CBService.characteristics` after a successful discovery call.
