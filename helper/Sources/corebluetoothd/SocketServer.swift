import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// A small Unix-domain-socket line server, built directly on POSIX sockets
// rather than Network.framework: the raw syscalls (socket/bind/listen/
// accept/read/write) are completely standard and unambiguous, which matters
// here because this helper is meant to be built and run only on macOS.
//
// Each connected client is read on its own background queue; complete lines
// (messages terminated by '\n') are handed to `onMessage`, whose completion
// closure writes the response back on the same connection. `broadcast(_:)`
// pushes a line to every currently-connected client (used for CoreBluetooth
// delegate events such as scan results and characteristic notifications).

enum PosixError: Error, CustomStringConvertible {
    case syscall(String, Int32)
    case pathTooLong

    var description: String {
        switch self {
        case .syscall(let name, let err):
            return "\(name) failed: \(String(cString: strerror(err)))"
        case .pathTooLong:
            return "socket path is too long for sockaddr_un"
        }
    }
}

final class ClientConnection {
    let fd: Int32
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var buffer = Data()
    private var isClosed = false

    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
        self.readQueue = DispatchQueue(label: "corebluetoothd.conn.read.\(fd)")
        self.writeQueue = DispatchQueue(label: "corebluetoothd.conn.write.\(fd)")
    }

    func start() {
        readQueue.async { [weak self] in self?.readLoop() }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            extractLines()
        }
        close(fd)
        isClosed = true
        onClose?()
    }

    private func extractLines() {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if !lineData.isEmpty {
                onLine?(lineData)
            }
        }
    }

    /// Named `send` rather than `write` so it can't be confused with (or
    /// accidentally shadow lookup of) the POSIX `write(2)` call used in its
    /// own implementation.
    func send(line data: Data) {
        writeQueue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            var payload = data
            payload.append(0x0A)
            payload.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < payload.count {
                    let n = write(self.fd, base + totalWritten, payload.count - totalWritten)
                    if n <= 0 { break }
                    totalWritten += n
                }
            }
        }
    }
}

final class SocketServer {
    private let socketPath: String
    private var serverFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "corebluetoothd.accept")
    private let connectionsLock = NSLock()
    private var connections: [Int32: ClientConnection] = [:]
    private var running = false

    /// Called for every complete line received from any client. The
    /// completion closure sends the response line back on that same
    /// connection.
    var onMessage: ((Data, @escaping (Data) -> Void) -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        unlink(socketPath) // clear a stale socket file from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PosixError.syscall("socket", errno) }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else { throw PosixError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = socketPath.withCString { cstr in
                strncpy(ptr, cstr, maxLen - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { rawAddr -> Int32 in
            rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw PosixError.syscall("bind", errno) }

        // The socket is a local IPC channel between one Go process and this
        // helper; restrict it to the current user.
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else { throw PosixError.syscall("listen", errno) }

        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                if !running { return }
                continue
            }
            let connection = ClientConnection(fd: clientFD)
            connectionsLock.lock()
            connections[clientFD] = connection
            connectionsLock.unlock()

            connection.onLine = { [weak self] data in
                self?.onMessage?(data) { responseData in
                    connection.send(line: responseData)
                }
            }
            connection.onClose = { [weak self] in
                self?.connectionsLock.lock()
                self?.connections.removeValue(forKey: clientFD)
                self?.connectionsLock.unlock()
            }
            connection.start()
        }
    }

    /// Sends a line to every currently connected client. Used for
    /// CoreBluetooth delegate events (scan results, notifications, state
    /// changes) which are not responses to any single request.
    func broadcast(_ data: Data) {
        connectionsLock.lock()
        let all = Array(connections.values)
        connectionsLock.unlock()
        for connection in all {
            connection.send(line: data)
        }
    }

    func stop() {
        running = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }
}
