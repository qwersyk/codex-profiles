import Foundation
import Darwin
import CryptoKit
import Security

/// RFC 6455 over a private Unix socket. No TCP port is opened.
public final class LocalWebSocket: @unchecked Sendable {
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "relay.local-writes")
    private let ready = DispatchGroup()
    private var descriptor: Int32 = -1
    private var stopped = false
    private let path: String
    private let onData: (Data) -> Void
    private let onClose: () -> Void
    private let onError: (Error) -> Void
    public init(path: String, onData: @escaping (Data) -> Void, onClose: @escaping () -> Void, onError: @escaping (Error) -> Void = { _ in }) {
        self.path = path; self.onData = onData; self.onClose = onClose; self.onError = onError
        ready.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in readLoop() }
    }
    deinit { close() }
    public func close() {
        lock.lock(); defer { lock.unlock() }; stopped = true
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    }
    public func send(_ data: Data) {
        writes.async { [self] in
            guard ready.wait(timeout: .now() + 6) == .success else { close(); return }
            do { try writeFrame(opcode: 1, data: data) } catch { close() }
        }
    }
    private func fd() throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, descriptor >= 0 else { throw RelayError.message("Local connection closed.") }; return descriptor
    }
    private func readLoop() {
        var didSignal = false
        defer {
            if !didSignal { ready.leave() }
            lock.lock(); let fd = descriptor; descriptor = -1; stopped = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
            lock.unlock(); onClose()
        }
        do {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var st = stat(), parent = stat()
            guard lstat(resolved, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFSOCK,
                  lstat(URL(fileURLWithPath: resolved).deletingLastPathComponent().path, &parent) == 0,
                  parent.st_uid == getuid(), parent.st_mode & 0o022 == 0 else {
                throw RelayError.message("Local Codex is unavailable or the socket permissions are unsafe.")
            }
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0); guard socketFD >= 0 else { throw RelayError.message("Could not open socket.") }
            lock.lock(); descriptor = socketFD; lock.unlock()
            var noSig: Int32 = 1; setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout.size(ofValue: noSig)))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(resolved.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RelayError.message("Socket path is too long.") }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { throw RelayError.message("Open ChatGPT through Relay.") }
            var random = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw RelayError.message("Could not create connection key.") }
            let key = Data(random).base64EncodedString()
            try writeAll(Data("GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
            var header = Data()
            while !header.suffix(4).elementsEqual([13,10,13,10]) {
                guard header.count < 8192 else { throw RelayError.message("Invalid local Codex response.") }; header += try take(1)
            }
            let text = String(decoding: header, as: UTF8.self)
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let headers = text.components(separatedBy: "\r\n")
            let accept = headers.first { $0.lowercased().hasPrefix("sec-websocket-accept:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("HTTP/1.1 101 "), accept == expected else { throw RelayError.message("Codex rejected the local connection.") }
            timeout = timeval(tv_sec: 0, tv_usec: 0); setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            didSignal = true; ready.leave()
            var message = Data(); var active = false
            while true {
                let h = [UInt8](try take(2)); let final = h[0] & 0x80 != 0, opcode = h[0] & 0x0F
                guard h[0] & 0x70 == 0, h[1] & 0x80 == 0 else { throw RelayError.message("Invalid WebSocket frame.") }
                var length = UInt64(h[1] & 0x7F)
                if length == 126 { length = try take(2).reduce(0) { ($0 << 8) | UInt64($1) } }
                if length == 127 { length = try take(8).reduce(0) { ($0 << 8) | UInt64($1) } }
                guard length <= 64 * 1024 * 1024 else { throw RelayError.message("Local response is too large.") }
                if opcode >= 8 { guard final, length <= 125 else { throw RelayError.message("Invalid control frame.") } }
                let body = try take(Int(length))
                switch opcode {
                case 8: return
                case 9:
                    writes.async { [self] in do { try writeFrame(opcode: 10, data: body) } catch { close() } }
                case 10: break
                case 1:
                    guard !active else { throw RelayError.message("Invalid frame order.") }; message = body; active = !final
                    if final { onData(message); message.removeAll(keepingCapacity: false) }
                case 0:
                    guard active, message.count + body.count <= 64 * 1024 * 1024 else { throw RelayError.message("Invalid continuation frame.") }
                    message += body; if final { active = false; onData(message); message.removeAll(keepingCapacity: false) }
                default: throw RelayError.message("Unsupported local frame.")
                }
            }
        } catch { onError(error); return }
    }
    private func take(_ count: Int) throws -> Data {
        if count == 0 { return Data() }
        var data = Data(count: count); var offset = 0
        while offset < count {
            let socketFD = try fd()
            let read = data.withUnsafeMutableBytes { ptr in recv(socketFD, ptr.baseAddress!.advanced(by: offset), count - offset, 0) }
            if read < 0 && errno == EINTR { continue }
            guard read > 0 else { throw RelayError.message("Codex disconnected.") }; offset += read
        }
        return data
    }
    private func writeAll(_ data: Data) throws {
        // Retain this socket while writing, even if the read loop closes its descriptor.
        lock.lock()
        let socketFD = !stopped && descriptor >= 0 ? dup(descriptor) : -1
        lock.unlock()
        guard socketFD >= 0 else { throw RelayError.message("Local connection closed.") }
        defer { Darwin.close(socketFD) }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in Darwin.send(socketFD, ptr.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw RelayError.message("Could not send message to Codex.") }; offset += written
        }
    }
    private func writeFrame(opcode: UInt8, data: Data) throws {
        var frame = Data([0x80 | opcode]); let n = data.count
        if n < 126 { frame.append(0x80 | UInt8(n)) }
        else if n <= 65535 { frame.append(0xFE); frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 255)) }
        else { frame.append(0xFF); for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(n) >> shift) & 255)) } }
        var mask = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, 4, &mask) == errSecSuccess else { throw RelayError.message("Could not create frame mask.") }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try writeAll(frame)
    }
}
