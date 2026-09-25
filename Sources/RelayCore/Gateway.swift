import Foundation

@MainActor public final class Gateway {
    public enum State: Equatable { case stopped, connecting, online, retrying(Int), failed(String) }
    public var onState: ((State) -> Void)?
    public var onPeerCount: ((Int) -> Void)?
    public var onMethod: ((String) -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    private let api: RemoteAPI
    private let paths: RelayPaths
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private let session: URLSession
    private var peers: [StreamKey: ProcessChannel] = [:]
    private var activity: [StreamKey: Date] = [:]
    private var legacy: [String: String] = [:]
    private var sequences: [StreamKey: Int] = [:]
    private var delivered: [StreamKey: Int] = [:]
    private var assembler = ChunkAssembler()
    private(set) var outbox = Outbox()
    private var cursor: String?
    private var writer: Task<Void, Never>?
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var generation = UUID()
    public init(api: RemoteAPI, paths: RelayPaths) {
        self.api = api; self.paths = paths
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config)
    }
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }
    public func stop() {
        runTask?.cancel(); runTask = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil
        writer?.cancel(); writer = nil; queue.removeAll(); queuedBytes = 0; generation = UUID()
        let old = peers; peers.removeAll(); for (_, p) in old { p.onClose = nil; p.close() }
        activity.removeAll(); delivered.removeAll(); sequences.removeAll(); legacy.removeAll(); assembler = ChunkAssembler(); outbox = Outbox(); cursor = nil
        onPeerCount?(0); onState?(.stopped)
    }
    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            onState?(.connecting)
            do {
                let e = try await api.ensureEnrollment(forceRefresh: attempt > 0)
                try Task.checkCancellation()
                let ws = session.webSocketTask(with: api.socketRequest(e, cursor: cursor))
                ws.maximumMessageSize = 160 * 1024; socket = ws; generation = UUID(); ws.resume()
                try await ping(ws)
                try Task.checkCancellation(); attempt = 0; onState?(.online)
                queue = outbox.frames.map(\.data); queuedBytes = outbox.bytes; pump()
                let heartbeat = Task { [weak self, weak ws] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: 10_000_000_000)
                            guard let self, let ws else { return }
                            try await self.ping(ws)
                            self.expirePeers()
                            if e.expires < Date().addingTimeInterval(180) { ws.cancel(with: .goingAway, reason: nil); return }
                        } catch { ws?.cancel(with: .goingAway, reason: nil); return }
                    }
                }
                defer { heartbeat.cancel() }
                while !Task.isCancelled {
                    let packet = try await ws.receive()
                    let data: Data
                    switch packet { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                    guard data.count <= 160 * 1024 else { throw RelayError.message("Unsupported Remote packet.") }
                    try await receive(JSON(data: data))
                }
            } catch {
                if Task.isCancelled { return }
                let failure = error as NSError
                let http = (socket?.response as? HTTPURLResponse)?.statusCode
                onDiagnostic?("Transport: \(failure.domain) \(failure.code), HTTP \(http.map(String.init) ?? "—")")
                writer?.cancel(); writer = nil; queue.removeAll(); queuedBytes = 0
                socket?.cancel(with: .goingAway, reason: nil); socket = nil; generation = UUID()
                if let apiError = error as? RemoteAPIError, [401, 403, 404].contains(apiError.status) {
                    onState?(.failed(apiError.localizedDescription)); runTask = nil; return
                }
                attempt += 1
                let requested = (error as? RemoteAPIError)?.retryAfter ?? 0
                let delay = max(requested, min(30, pow(2, Double(min(attempt, 5))))) + Double.random(in: 0...1)
                onState?(.retrying(Int(delay)))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) } catch { return }
            }
        }
    }
    private func ping(_ ws: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let gate = PingCompletion(c)
            ws.sendPing { error in gate.finish(error) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { gate.finish(URLError(.timedOut)) }
        }
    }
    func receive(_ envelope: JSON) async throws {
        guard let client = envelope["client_id"].string, !client.isEmpty, client.count < 256, let type = envelope["type"].string else { throw RelayError.message("Unsupported Remote version.") }
        let message = envelope["message"]
        let isInit = message["method"].string == "initialize"
        let stream: String
        if let explicit = envelope["stream_id"].string { stream = explicit }
        else if let saved = legacy[client] { stream = saved }
        else { stream = UUID().uuidString; if isInit { legacy[client] = stream } }
        guard !stream.isEmpty, stream.count < 256 else { return }
        let key = StreamKey(client: client, stream: stream)
        switch type {
        case "ack":
            if let seq = envelope["seq_id"].int { outbox.acknowledge(key: key, sequence: seq, segment: envelope["segment_id"].int) }
        case "ping":
            if peers[key] != nil { activity[key] = Date() }
            try enqueueEvent(.object(["type": .string("pong"), "status": .string(peers[key] == nil ? "unknown" : "active")]), key: key)
        case "client_closed": closePeer(key)
        case "client_message", "client_message_chunk":
            let seq = envelope["seq_id"].int
            if let seq, let last = delivered[key], seq <= last { break }
            let complete: JSON
            if type == "client_message_chunk" { guard let m = try assembler.accept(envelope, key: key) else { return }; complete = m }
            else { complete = message }
            do { try await forward(complete, key: key) }
            catch {
                closePeer(key)
                onDiagnostic?("Open ChatGPT through Relay on this Mac.")
                if complete["id"] != .null {
                    try emit(.object(["id": complete["id"], "error": .object([
                        "code": .number(-32000), "message": .string("Start ChatGPT through Relay on your Mac, then reconnect this host.")
                    ])]), key: key)
                }
            }
            if let seq { delivered[key] = seq }
        default: throw RelayError.message("Unknown Remote message type.")
        }
        if let next = envelope["cursor"].string { cursor = next }
    }
    private func forward(_ message: JSON, key: StreamKey) async throws {
        if let method = message["method"].string {
            onMethod?(method)
            if !WireProtocol.permits(method) {
                if message["id"] != .null { try emit(.object(["id": message["id"], "error": .object(["code": .number(-32601), "message": .string("This operation is available only on the Mac.")])]), key: key) }; return
            }
            if method == "initialize" {
                closePeer(key)
                guard peers.count < 8 else { throw RelayError.message("Connection limit reached.") }
                // Query the work account's policy without enabling its native Remote transport.
                let check = ProcessChannel()
                try check.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
                defer { check.close() }
                _ = try await check.initialize(name: "relay_policy_check")
                _ = try await check.call("remoteControl/status/read")
                let peer = ProcessChannel()
                try peer.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
                peers[key] = peer
                peer.onMessage = { [weak self, weak peer] response in
                    guard let self, self.peers[key] === peer else { return }
                    do { try self.emit(response, key: key) } catch { self.closePeer(key); self.onState?(.failed("Remote buffer is full. Reopen the task on your phone.")) }
                }
                peer.onClose = { [weak self, weak peer] in
                    guard let self, self.peers[key] === peer else { return }; self.closePeer(key)
                }
                onPeerCount?(peers.count)
            }
        }
        guard let peer = peers[key] else {
            if message["id"] != .null {
                try emit(.object(["id": message["id"], "error": .object([
                    "code": .number(-32000),
                    "message": .string("The local session disconnected. Reopen this host in Remote; pairing is still saved.")
                ])]), key: key)
            }
            return
        }
        activity[key] = Date(); try peer.send(message)
    }
    private func emit(_ message: JSON, key: StreamKey) throws {
        let seq = sequences[key, default: 1]; sequences[key] = seq + 1
        let frames = try WireProtocol.frames(message: message, key: key, sequence: seq)
        try outbox.append(frames)
        if socket != nil { for f in frames { try enqueue(f.data) } }
    }
    private func enqueueEvent(_ event: JSON, key: StreamKey) throws {
        var event = event
        let seq = sequences[key, default: 1]; sequences[key] = seq + 1
        event["client_id"] = .string(key.client); event["stream_id"] = .string(key.stream); event["seq_id"] = .number(Double(seq))
        let frame = OutboundFrame(key: key, sequence: seq, segment: nil, data: try event.data())
        try outbox.append([frame]); if socket != nil { try enqueue(frame.data) }
    }
    private func enqueue(_ data: Data) throws {
        guard queuedBytes + data.count < 48 * 1024 * 1024 else { throw RelayError.message("Remote queue is full.") }
        queue.append(data); queuedBytes += data.count; pump()
    }
    private func pump() {
        guard writer == nil, let socket, !queue.isEmpty else { return }
        let current = generation
        writer = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            defer { if self.generation == current { self.writer = nil } }
            while !Task.isCancelled, self.generation == current, !self.queue.isEmpty {
                let data = self.queue.removeFirst(); self.queuedBytes -= data.count
                do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
                catch { socket.cancel(with: .goingAway, reason: nil); return }
            }
        }
    }
    private func closePeer(_ key: StreamKey) {
        let p = peers.removeValue(forKey: key); p?.onClose = nil; p?.close()
        activity.removeValue(forKey: key); assembler.remove(key); delivered.removeValue(forKey: key)
        // Keep monotonically increasing sequence ids within a stream, including re-initialize.
        outbox.remove(key); onPeerCount?(peers.count)
    }
    private func expirePeers() {
        for (key, time) in activity where Date().timeIntervalSince(time) > 300 { closePeer(key) }
    }
}

private final class PingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
    func finish(_ error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}
