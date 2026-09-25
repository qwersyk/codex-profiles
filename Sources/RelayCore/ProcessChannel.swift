import Foundation

/// Newline-framed app-server connection. Each remote stream gets its own connection.
@MainActor public final class ProcessChannel {
    private var local: LocalWebSocket?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    public var onMessage: ((JSON) -> Void)?
    public var onClose: (() -> Void)?
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var ended = false
    private var closeError: Error?
    public init() {}
    public func start(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
        if let i = arguments.firstIndex(of: "--sock"), arguments.contains("proxy"), arguments.indices.contains(i + 1) {
            local = LocalWebSocket(path: arguments[i + 1], onData: { [weak self] data in
                Task { @MainActor in var line = data; line.append(10); self?.receive(line) }
            }, onClose: { [weak self] in Task { @MainActor in self?.finish() } }, onError: { [weak self] error in Task { @MainActor in self?.closeError = error } })
            return
        }
        guard process == nil else { throw RelayError.message("Connection is already open.") }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.environment = environment; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.finish() } }
        do { try p.run() } catch { finish(); throw error }
    }
    private func receive(_ data: Data) {
        guard !ended else { return }
        guard !data.isEmpty else { finish(); return }
        buffer.append(data)
        guard buffer.count <= 64 * 1024 * 1024 else { close(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard !line.isEmpty, let message = try? JSON(data: line) else { continue }
            if let id = message["id"].string, let waiter = pending.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id)?.cancel()
                if message["error"] != .null { waiter.resume(throwing: RelayError.message(message["error"]["message"].string ?? "Codex error.")) }
                else { waiter.resume(returning: message["result"]) }
            } else { onMessage?(message) }
        }
    }
    public func send(_ value: JSON) throws {
        if let local, !ended { local.send(try value.data()); return }
        guard !ended, let input else { throw RelayError.message("Codex connection closed.") }
        var data = try value.data(); data.append(10); try input.write(contentsOf: data)
    }
    public func call(_ method: String, _ params: JSON = .object([:]), timeout: Double = 30) async throws -> JSON {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) } catch { return }
                    guard let self, let p = self.pending.removeValue(forKey: id) else { return }
                    self.deadlines.removeValue(forKey: id); p.resume(throwing: RelayError.message("Codex did not respond in time."))
                }
                do { try send(.object(["id": .string(id), "method": .string(method), "params": params])) }
                catch { deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }, onCancel: { Task { @MainActor [weak self] in
            self?.deadlines.removeValue(forKey: id)?.cancel()
            self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        } })
    }
    public func initialize(name: String) async throws -> JSON {
        let response = try await call("initialize", .object(["clientInfo": .object(["name": .string(name), "version": .string("0.1.0")]), "capabilities": .object(["experimentalApi": .bool(true)])]))
        try send(.object(["method": .string("initialized")])); return response
    }
    private func finish() {
        guard !ended else { return }; ended = true
        local?.close(); local = nil
        output?.readabilityHandler = nil; try? input?.close(); try? output?.close()
        for (_, task) in deadlines { task.cancel() }; deadlines.removeAll()
        let waiters = pending.values; pending.removeAll()
        for p in waiters { p.resume(throwing: closeError ?? RelayError.message("Codex disconnected.")) }
        onClose?()
    }
    public func close() { if process?.isRunning == true { process?.terminate() }; finish() }
}
