import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// corebluetoothd: a tiny helper process that owns a CBCentralManager and
// speaks a line-delimited JSON-RPC 2.0 protocol over a Unix domain socket.
// It is meant to be spawned as a subprocess by another process (typically a
// Go program that cannot use CoreBluetooth directly without cgo) and torn
// down when that parent exits. See ../../PROTOCOL.md for the wire protocol.

setbuf(stdout, nil) // make sure "READY" is flushed immediately, unbuffered

struct Args {
    var socketPath: String
    var parentPID: Int32?
}

func parseArgs() -> Args {
    let arguments = CommandLine.arguments
    var socketPath: String?
    var parentPID: Int32?

    var i = 1
    while i < arguments.count {
        switch arguments[i] {
        case "--socket":
            i += 1
            if i < arguments.count { socketPath = arguments[i] }
        case "--parent-pid":
            i += 1
            if i < arguments.count { parentPID = Int32(arguments[i]) }
        default:
            break
        }
        i += 1
    }

    guard let socketPath = socketPath else {
        FileHandle.standardError.write("usage: corebluetoothd --socket <path> [--parent-pid <pid>]\n".data(using: .utf8)!)
        exit(2)
    }
    return Args(socketPath: socketPath, parentPID: parentPID)
}

let args = parseArgs()

let central = BluetoothCentral()

// Block briefly for CoreBluetooth's first state callback before accepting
// connections: CBCentralManager starts in `.unknown` and only reports its
// real state (poweredOn/poweredOff/unauthorized/...) asynchronously, so
// without this a client that calls state.get immediately after connecting
// can race CoreBluetooth's own initialization and observe a stale
// "unknown". Bounded so a genuinely stuck adapter/permission prompt can't
// hang the helper forever - if it times out, state.get will just report
// whatever CoreBluetooth has (likely still "unknown"), which at least is
// now a real signal that something's wrong rather than a startup race.
let initialStateReady = DispatchSemaphore(value: 0)
central.onFirstState = { initialStateReady.signal() }
_ = initialStateReady.wait(timeout: .now() + 5)

let server = SocketServer(socketPath: args.socketPath)
let dispatcher = RPCDispatcher(central: central, server: server)
server.onMessage = { data, respond in
    dispatcher.handle(data: data, respond: respond)
}

do {
    try server.start()
} catch {
    FileHandle.standardError.write("failed to start socket server: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// Signal readiness on stdout. The Go client waits for this line instead of
// blindly polling the socket, so startup is fast and deterministic.
print("READY \(args.socketPath)")

// Watchdog: if the parent process (the Go program that spawned us) has
// died without giving us a chance to clean up, exit rather than leaking an
// orphaned helper that holds the Bluetooth radio and a stale socket file.
if let parentPID = args.parentPID {
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 2, repeating: 2)
    watchdog.setEventHandler {
        if kill(parentPID, 0) != 0 && errno == ESRCH {
            server.stop()
            exit(0)
        }
    }
    watchdog.resume()
}

signal(SIGTERM) { _ in
    server.stop()
    exit(0)
}
signal(SIGINT) { _ in
    server.stop()
    exit(0)
}

// CBCentralManager delegate callbacks are delivered on their own dedicated
// queue (see BluetoothCentral.init), so the main thread just needs to stay
// parked for the process lifetime.
dispatchMain()
