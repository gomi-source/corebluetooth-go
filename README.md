# corebluetooth-go

Lets a Go program drive macOS CoreBluetooth (central/client role: scan,
connect, discover, read/write/notify) **without cgo**.

## How it works

Go can't call Objective-C/Swift frameworks directly without cgo, and
CoreBluetooth has no C API. So instead of binding to it in-process, this
splits the work across two processes:

```
your Go program  <--Unix socket, JSON-RPC-->  corebluetoothd (Swift helper)  <--CoreBluetooth-->  BLE hardware
   (ble)                                    (helper/)
```

- **`helper/`** - a Swift Package Manager executable, `corebluetoothd`. It
  owns the one `CBCentralManager` for the process, and exposes scan/
  connect/discover/read/write/notify over a line-delimited JSON-RPC 2.0
  protocol on a Unix domain socket. See [`PROTOCOL.md`](./PROTOCOL.md) for
  the exact wire format.
- **`ble/`** - a pure-Go client package (`go build` needs no cgo, no
  CGO_ENABLED=1, nothing beyond the standard library). `ble.Start()`
  spawns `corebluetoothd` as a subprocess, dials the socket, and gives you
  a typed Go API plus channels for async events (discovered peripherals,
  characteristic notifications, disconnects, state changes).
- **`example/scan/`** - a minimal program that scans for 10 seconds and
  prints what it finds.

### Why a Unix socket + JSON-RPC, not HTTP or gRPC

CoreBluetooth is entirely delegate/callback-driven: `scanForPeripherals`
produces an unbounded stream of `didDiscoverPeripheral` callbacks, a
`notify` characteristic pushes updates indefinitely, connection state
changes arrive whenever the OS gets to them. Whatever sits between Go and
the helper needs both request/response (send a command, get an ack or
value) *and* unsolicited server-to-client push, on the same channel.

- Plain HTTP/REST doesn't have a good story for the push half without
  bolting on SSE/WebSocket as a second channel.
- gRPC's bidi streaming is a very natural fit for this, but drags in
  grpc-swift + protoc codegen on the Swift side for what's fundamentally a
  local, single-client integration.
- XPC would be the "native" macOS IPC choice, but Go can't speak it
  without cgo.

A Unix domain socket carrying JSON-RPC 2.0 needs zero extra dependencies
on either side (`Foundation` on Swift, `encoding/json` + `net` on Go, both
already in the standard library), and JSON-RPC's request/notification
split maps directly onto "commands" vs. "CoreBluetooth delegate events".
It's also trivially inspectable with `nc`/`socat` while debugging.

## Building

Requires macOS with Xcode/Swift toolchain installed (the helper links
CoreBluetooth, so it can only be built and run on macOS - the Go client
code itself is plain Go and builds anywhere, but obviously only *does*
anything on macOS since that's the only place `corebluetoothd` can run).

```sh
make helper      # swift build -c release, ad-hoc codesigns the binary
make go-build    # go build ./...
make example     # builds both and drops bin/scan + bin/corebluetoothd
./bin/scan
```

`ble.Start()` looks for `corebluetoothd` next to your Go binary's own
path, then on `$PATH`, or you can point it at an explicit path via
`ble.Options.HelperPath`.

## Using it from your own Go program

```go
client, err := ble.Start(ctx, ble.Options{Stderr: os.Stderr})
if err != nil { log.Fatal(err) }
defer client.Close()

if err := client.StartScan(ctx, ble.ScanOptions{}); err != nil {
    log.Fatal(err)
}
for p := range client.Discoveries() {
    fmt.Println(p.PeripheralID, p.RSSI, p.Name)
}
```

```go
if err := client.Connect(ctx, peripheralID, 5*time.Second); err != nil { ... }
services, err := client.DiscoverServices(ctx, peripheralID, nil)
chars, err := client.DiscoverCharacteristics(ctx, peripheralID, services[0].UUID, nil)
value, err := client.ReadCharacteristic(ctx, peripheralID, services[0].UUID, chars[0].UUID)

client.SetNotify(ctx, peripheralID, services[0].UUID, chars[0].UUID, true)
for update := range client.Notifications() {
    // update.ValueBase64, decode with encoding/base64
}
```

`Client` owns the `corebluetoothd` subprocess: `Start` spawns it (passing
its own PID via `--parent-pid` so the helper self-terminates if your
process dies without calling `Close`), and `Close` sends it `SIGTERM` and
cleans up the socket file.

## macOS Bluetooth permission

Since macOS 11, using CoreBluetooth requires the user to grant Bluetooth
access under **System Settings > Privacy & Security > Bluetooth**. For a
plain command-line binary (no `.app` bundle / `Info.plist`), macOS
attributes that permission to whichever process actually invoked
`corebluetoothd` - in practice, your Go binary (or the terminal, if you're
running `go run`). The first scan will trigger the permission prompt; if
it doesn't, or scanning silently returns nothing, check that entry in
Privacy & Security manually.

Ad-hoc codesigning the helper (which `make helper` does via `codesign
--sign -`) gives it a stable identity across rebuilds, which keeps macOS
from treating every rebuilt binary as a "new" app requiring re-approval.
If you ship this to other machines, sign it with a real Developer ID
instead. If you hit persistent permission issues, wrapping `corebluetoothd`
in a minimal `.app` bundle with an `Info.plist` that sets
`NSBluetoothAlwaysUsageDescription` gives you the most reliable/standard
permission-prompt behavior - not done here to keep the helper a plain
single binary, but worth doing if this moves beyond development use.

## Scope / what's not here

- Central role only (scan/connect/read/write/notify as a BLE client).
  No peripheral role (advertising / acting as a GATT server) - see
  `helper/Sources/corebluetoothd/BluetoothCentral.swift` if you want to
  add a `CBPeripheralManager` counterpart following the same pattern.
- One client connection is the assumed use case (`ble.Start` spawns a
  private helper per Go process, socket path includes the PID), though
  the socket server itself will happily broadcast events to multiple
  connections if you build on top of it directly.
- See "Known simplifications" in [`PROTOCOL.md`](./PROTOCOL.md) for the
  `didUpdateValueFor` read/notify disambiguation edge case.
