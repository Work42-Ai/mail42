// ServeSocket.swift — the few POSIX socket calls the `serve` daemon and its CLI client share.
//
// A Unix stream socket, one JSON object per line (docs/serve-protocol.md). Nothing here knows about mail.

import Darwin
import Foundation

enum ServeSocket {

    /// The longest path a Unix socket address can hold on macOS (`sun_path` is 104 bytes, one is the terminator).
    static let maxPathLength = 103

    /// A socket address for `path`, or nil when the path doesn't fit in `sun_path`.
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        return address
    }

    static func withSockaddr<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var copy = address
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Connects to the socket at `path`, giving up after `timeoutMs`. Nil when nobody is listening (no file, a stale
    /// file, a daemon that is busy past the timeout).
    static func connect(path: String, timeoutMs: Int32) -> Int32? {
        guard let address = address(for: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var result = withSockaddr(address) { Darwin.connect(fd, $0, $1) }
        if result != 0, errno == EINPROGRESS || errno == EAGAIN {
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&poller, 1, timeoutMs) > 0 {
                var failure: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
                result = failure == 0 ? 0 : -1
            } else {
                result = -1
            }
        }
        guard result == 0 else { close(fd); return nil }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// Writes all of `data`. False when the other end is gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    /// Reads up to the next newline (not included), keeping what follows in `buffer`. Nil on end of stream, error,
    /// timeout (`timeoutMs`, when given) or a line longer than `limit`.
    static func readLine(_ fd: Int32, buffer: inout Data, timeoutMs: Int32? = nil, limit: Int = 1 << 20) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            if buffer.count > limit { return nil }
            if let timeoutMs {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, timeoutMs)
                if ready <= 0 { return nil }
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }
            buffer.append(chunk, count: count)
        }
    }

    /// One JSON object as a line.
    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}

/// Comparing mail42 versions (`0.3.0`, `1.10.2`, `0.3.0-beta`): numeric parts, missing parts count as 0.
enum ServeVersion {
    static func parts(_ version: String) -> [Int] {
        version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
    }

    /// -1 when `lhs` is older than `rhs`, 0 when equal, 1 when newer.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let (a, b) = (parts(lhs), parts(rhs))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
