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

    /// Listening socket on [::1]:port (IPv6 only, so it can share the port with the 127.0.0.1 listener).
    public static func listenIPv6Loopback(port: Int) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(what: "socket", code: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        addr.sin6_addr = in6addr_loopback
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw Failure(what: "bind [::1]:\(port)", code: e) }
        guard Darwin.listen(fd, 64) == 0 else { let e = errno; close(fd); throw Failure(what: "listen", code: e) }
        return fd
    }

    /// Listening socket on a specific IPv4 address (e.g. the container gateway).
    public static func listen(address: String, port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(what: "socket", code: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(address)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw Failure(what: "bind \(address):\(port)", code: e) }
        guard Darwin.listen(fd, 64) == 0 else { let e = errno; close(fd); throw Failure(what: "listen", code: e) }
        return fd
    }

    /// Dual-stack wildcard listener ([::]:port, also accepting IPv4). macOS lets normal users bind ports
    /// below 1024 only on the wildcard address, so callers must filter peers with `peerIsLoopback`.
    public static func listenAnyDualStack(port: Int) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(what: "socket", code: errno) }
        var one: Int32 = 1, zero: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        addr.sin6_addr = in6addr_any
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw Failure(what: "bind [::]:\(port)", code: e) }
        guard Darwin.listen(fd, 64) == 0 else { let e = errno; close(fd); throw Failure(what: "listen", code: e) }
        return fd
    }

    /// True when the connected peer is 127.0.0.0/8, ::1 or IPv4-mapped loopback.
    public static func peerIsLoopback(_ fd: Int32) -> Bool {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        guard rc == 0 else { return false }
        return withUnsafePointer(to: &addr) { p -> Bool in
            switch Int32(p.pointee.ss_family) {
            case AF_INET:
                return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) >> 24 == 127 }
            case AF_INET6:
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    let b = withUnsafeBytes(of: a.pointee.sin6_addr) { Array($0) }
                    let isV6Loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
                    let isMappedV4Loopback = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF && b[12] == 127
                    return isV6Loopback || isMappedV4Loopback
                }
            default: return false
            }
        }
    }

    /// Local port a socket is bound to (useful after binding port 0).
    public static func boundPort(_ fd: Int32) -> Int? {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { return nil }
        return withUnsafePointer(to: &addr) { p -> Int? in
            switch Int32(p.pointee.ss_family) {
            case AF_INET: p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
            case AF_INET6: p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
            default: nil
            }
        }
    }

    /// Sets (or clears, with nil) the receive timeout of a socket.
    public static func setReadTimeout(_ fd: Int32, seconds: Int?) {
        var tv = timeval(tv_sec: seconds ?? 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads until `terminator` has been received, the peer closes, an error/timeout occurs, or `limit` bytes are read.
    /// Returns everything read (which may extend past the terminator) and whether the terminator was seen.
    public static func readUntil(_ fd: Int32, _ terminator: [UInt8], limit: Int) -> (bytes: [UInt8], complete: Bool) {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while out.count < limit {
            let want = min(buf.count, limit - out.count)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            // Only the newly read bytes (plus a small overlap) can complete the terminator.
            let searchFrom = max(0, out.count - terminator.count + 1)
            out.append(contentsOf: buf[0..<n])
            if out[searchFrom...].firstRange(of: terminator) != nil { return (out, true) }
        }
        return (out, false)
    }

    /// Writes all bytes; false if the peer went away.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let w = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
            if w < 0, errno == EINTR { continue }
            guard w > 0 else { return false }
            off += w
        }
        return true
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
