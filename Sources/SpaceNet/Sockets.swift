import Darwin
import Foundation

/// Minimal POSIX TCP helpers for loopback listeners and the byte relay.
/// Everything here is blocking and runs on dedicated threads; connection counts are tiny (local dev).
public enum Sockets {
    public struct Failure: Error, CustomStringConvertible {
        public let what: String
        public let code: Int32
        public var description: String { "\(what): \(String(cString: strerror(code)))" }
    }

    private static func loopback(_ port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }

    private static func withSockaddr<R>(_ port: Int, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var addr = loopback(port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    private static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Listening socket on 127.0.0.1:port.
    public static func listen(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(what: "socket", code: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard withSockaddr(port, { bind(fd, $0, $1) }) == 0 else {
            let e = errno; close(fd); throw Failure(what: "bind 127.0.0.1:\(port)", code: e)
        }
        guard Darwin.listen(fd, 64) == 0 else { let e = errno; close(fd); throw Failure(what: "listen", code: e) }
        return fd
    }

    /// Connected socket to 127.0.0.1:port.
    public static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(what: "socket", code: errno) }
        noSigPipe(fd)
        guard withSockaddr(port, { Darwin.connect(fd, $0, $1) }) == 0 else {
            let e = errno; close(fd); throw Failure(what: "connect 127.0.0.1:\(port)", code: e)
        }
        return fd
    }

    public static func isFree(port: Int) -> Bool {
        guard let fd = try? listen(port: port) else { return false }
        close(fd)
        return true
    }

    /// First free loopback port, preferring `preferred`, then scanning from `fallbackStart`.
    public static func freePort(preferred: Int, fallbackStart: Int = 15000) -> Int? {
        if isFree(port: preferred) { return preferred }
        return (fallbackStart..<(fallbackStart + 2000)).first(where: isFree(port:))
    }

    /// Accepts on `listener` until it is closed, handing each connection to `handler` on its own thread.
    public static func acceptLoop(_ listener: Int32, accept: @escaping @Sendable (Int32) -> Int32?, handler: @escaping @Sendable (Int32) -> Void) {
        Thread.detachNewThread {
            while let conn = accept(listener) {
                noSigPipe(conn)
                Thread.detachNewThread { handler(conn) }
            }
        }
    }

    /// Plain POSIX accept; nil once the listener is closed.
    public static func posixAccept(_ listener: Int32) -> Int32? {
        while true {
            let c = Darwin.accept(listener, nil, nil)
            if c >= 0 { return c }
            if errno == EINTR { continue }
            return nil
        }
    }

    /// Copies bytes both ways until either side closes, then closes both.
    public static func relay(_ a: Int32, _ b: Int32) {
        let done = DispatchGroup()
        for (src, dst) in [(a, b), (b, a)] {
            done.enter()
            Thread.detachNewThread {
                pump(from: src, to: dst)
                shutdown(dst, SHUT_WR)
                done.leave()
            }
        }
        done.wait()
        close(a)
        close(b)
    }

    private static func pump(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { read(src, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(dst, $0.baseAddress! + off, n - off) }
                if w < 0, errno == EINTR { continue }
                guard w > 0 else { return }
                off += w
            }
        }
    }
}
