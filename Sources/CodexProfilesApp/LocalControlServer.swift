import Foundation
import Network
import RelayCore
import Darwin

/// Small LAN-only HTTP server used by Markdown links in the virtual Remote chat.
/// It never serves credentials; each launch gets a fresh control token.
@MainActor
final class LocalControlServer {
    var profileOptions: (() -> [RemoteProfileOption])?
    var onProfileSwitch: ((UUID) async -> String?)?

    private var listener: NWListener?
    private var token = UUID().uuidString.lowercased()
    private(set) var isRunning = false
    private let port: NWEndpoint.Port = 63099

    var baseURL: String? {
        guard isRunning, let address = localIPv4 else { return nil }
        return "http://\(address):\(port.rawValue)/switch/%d?token=\(token)"
    }

    func start() {
        guard listener == nil else { return }
        token = UUID().uuidString.lowercased()
        guard let listener = try? NWListener(using: .tcp, on: port) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.isRunning = true
                case .failed, .cancelled:
                    self.isRunning = false
                    self.listener = nil
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, isComplete, _ in
            guard let self else { connection.cancel(); return }
            var combined = data
            if let chunk { combined.append(chunk) }
            if let request = String(data: combined, encoding: .utf8), request.contains("\r\n\r\n") {
                Task { @MainActor in self.handle(request, on: connection) }
            } else if !isComplete && combined.count < 16 * 1024 {
                Task { @MainActor in self.receive(connection, data: combined) }
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ request: String, on connection: NWConnection) {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else {
            respond(status: "400 Bad Request", body: "Bad request.", on: connection)
            return
        }
        let parts = line.split(separator: " ")
        guard parts.count == 3, ["GET", "POST"].contains(parts[0]) else {
            respond(status: "405 Method Not Allowed", body: "Unsupported request.", on: connection)
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://relay\(target)"),
              components.queryItems?.first(where: { $0.name == "token" })?.value == token else {
            respond(status: "403 Forbidden", body: "This control link has expired. Refresh /accounts in Remote.", on: connection)
            return
        }
        let path = components.path
        guard path.hasPrefix("/switch/"), let number = Int(path.dropFirst("/switch/".count)) else {
            respond(status: "404 Not Found", body: "Unknown Codex Profiles action.", on: connection)
            return
        }
        let options = profileOptions?() ?? []
        guard options.indices.contains(number - 1) else {
            respond(status: "404 Not Found", body: "That profile is no longer available.", on: connection)
            return
        }
        let targetProfile = options[number - 1]
        if method == "GET" {
            let escapedName = Self.htmlEscape(targetProfile.name)
            let html = """
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{font:18px -apple-system,system-ui;margin:40px auto;max-width:450px;padding:0 22px;background:#161719;color:#eee}button{font:inherit;background:#2766d9;color:white;border:0;border-radius:12px;padding:15px 22px}</style>
            <h2>Codex Profiles</h2><p>Switch Codex on your Mac to <b>\(escapedName)</b>?</p>
            <form method="post" action="\(Self.htmlEscape(target))"><button type="submit">Switch profile</button></form>
            """
            respond(status: "200 OK", html: html, on: connection)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let onProfileSwitch = self.onProfileSwitch else { connection.cancel(); return }
            let error = await onProfileSwitch(targetProfile.id)
            let message = error ?? "Codex switched to \(targetProfile.name). You can return to ChatGPT Remote."
            self.respond(status: error == nil ? "200 OK" : "500 Internal Server Error", body: message, on: connection)
        }
    }

    private func respond(status: String, body: String, on connection: NWConnection) {
        let escaped = Self.htmlEscape(body)
        let html = "<meta name=\"viewport\" content=\"width=device-width\"><h2>Codex Profiles</h2><p>\(escaped)</p>"
        respond(status: status, html: html, on: connection)
    }

    private func respond(status: String, html: String, on connection: NWConnection) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private var localIPv4: String? {
        var addresses: [(String, String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  item.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(item.pointee.ifa_addr, socklen_t(item.pointee.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addresses.append((String(cString: item.pointee.ifa_name), String(cString: host)))
        }
        return addresses.first(where: { $0.0 == "en0" })?.1
            ?? addresses.first(where: { $0.0 == "en1" })?.1
            ?? addresses.first(where: { $0.0.hasPrefix("en") })?.1
    }
}
