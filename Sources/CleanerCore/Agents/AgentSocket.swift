import Darwin
import Foundation

/// The local socket between `mucli agent-hook` and the app.
///
/// A file in UniMacHub's support folder that only this user may open, so nothing else on the
/// Mac, and nothing on the network, can pretend to be Claude Code or answer its questions.
/// Each call is one line of JSON in and one line back.
public enum AgentSocket {
    /// Sends one line and waits for one line back. Nil when the app is not listening or
    /// does not answer in time.
    public static func send(_ line: Data, to path: String, timeout: TimeInterval) -> Data? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(socket, timeout)
        guard var address = address(for: path) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        guard writeAll(socket, line + Data([0x0A])) else { return nil }
        return readLine(socket)
    }

    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func setTimeout(_ socket: Int32, _ seconds: TimeInterval) {
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ socket: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Up to the first newline, or the end; at most a megabyte.
    static func readLine(_ socket: Int32) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while result.count < 1024 * 1024 {
            let count = read(socket, &buffer, buffer.count)
            if count < 0 { return result.isEmpty ? nil : result }
            if count == 0 { break }
            result.append(contentsOf: buffer[0 ..< count])
            if let newline = result.firstIndex(of: 0x0A) { return result[..<newline] }
        }
        return result
    }
}

/// The answer to one call, which can wait: a question for the person stays open until they
/// answer it.
public final class AgentReply: @unchecked Sendable {
    private let socket: Int32
    private let lock = NSLock()
    private var sent = false

    init(socket: Int32) {
        self.socket = socket
    }

    /// Answers and hangs up. Only the first answer counts.
    public func send(_ line: Data = Data()) {
        lock.lock()
        defer { lock.unlock() }
        guard !sent else { return }
        sent = true
        _ = AgentSocket.writeAll(socket, line + Data([0x0A]))
        close(socket)
    }

    deinit {
        if !sent { close(socket) }
    }
}

/// The app's end of the socket.
public final class AgentSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data, AgentReply) -> Void

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.fixerhack.unimachub.agents")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        guard source == nil else { return }
        try FileManager.default.createDirectory(
            at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        unlink(path)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0, var address = AgentSocket.address(for: path) else { throw POSIXError(.EINVAL) }
        // Created closed to everyone else, before it exists on disk.
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0, listen(socket, 16) == 0 else {
            close(socket)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        listener = socket
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(socket) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        listener = -1
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            // A caller that sends nothing does not hold up the next one for long.
            AgentSocket.setTimeout(client, 2)
            guard let line = AgentSocket.readLine(client), !line.isEmpty else {
                close(client)
                continue
            }
            handler(Data(line), AgentReply(socket: client))
        }
    }
}
