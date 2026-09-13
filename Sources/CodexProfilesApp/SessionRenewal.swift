import Foundation
import Darwin

/// Local claims describe the saved session, not a live billing entitlement.
struct SessionMetadata {
    let plan: String?
    let expiresAt: Date?
    let refreshToken: String?
    let isManaged: Bool

    init(data: Data) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let access = Self.payload(tokens["access_token"] as? String)
        let identity = Self.payload(tokens["id_token"] as? String)
        let rawPlan = (identity["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
            ?? (access["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        let knownPlans = ["free", "go", "plus", "pro", "team", "business", "enterprise", "edu"]
        plan = rawPlan.flatMap { knownPlans.contains($0.lowercased()) ? $0.capitalized : nil }
        expiresAt = (access["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
        refreshToken = (tokens["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let apiKey = (json["OPENAI_API_KEY"] as? String) ?? ""
        isManaged = apiKey.isEmpty && (json["auth_mode"] as? String != "chatgptAuthTokens") && refreshToken != nil
    }

    func needsRenewal(now: Date, lastAttempt: Date?) -> Bool {
        guard isManaged, let expiresAt, expiresAt <= now.addingTimeInterval(86_400) else { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= 86_400 } ?? true
    }

    private static func payload(_ token: String?) -> [String: Any] {
        guard let parts = token?.split(separator: "."), parts.count == 3 else { return [:] }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

enum SessionRenewalError: LocalizedError {
    case unavailable, active, shared, failed, timeout, unchanged

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This profile has no managed refresh token. Sign in again to save a renewable session."
        case .active: return "ChatGPT manages renewal for the active account. Switch to another account before renewing this saved session."
        case .shared: return "Another saved profile shares this refresh token. Sign in separately to avoid invalidating its session."
        case .failed: return "Session renewal failed. Check your connection and try again, or sign in again if the session was revoked."
        case .timeout: return "Session renewal timed out. Any credentials already renewed by Codex remain saved."
        case .unchanged: return "Codex did not save a renewed access token. Update ChatGPT or sign in again."
        }
    }
}

/// Uses Codex's managed OAuth implementation. No prompts, model calls, or logout requests.
@MainActor
enum SessionRenewal {
    static func renew(executable: URL, home: URL, timeout: TimeInterval = 30) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("response.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let writer = try FileHandle(forWritingTo: outputURL)
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? writer.close(); try? reader.close() }
        let input = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "-c", "cli_auth_credentials_store=\"file\"", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        // A provider key inherited from the shell must not override this saved account.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        try process.run()
        let outcome: Result<Void, Error>
        do {
            try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "codex_profiles", "title": "Codex Profiles", "version": "1.6"]]], to: input)
            var pending = Data()
            var totalBytes = 0
            var initialized = false
            var finished = false
            var observedExit = false
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !finished {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SessionRenewalError.timeout }
                let chunk = try reader.read(upToCount: 65_536) ?? Data()
                totalBytes += chunk.count
                guard totalBytes <= 1_048_576 else { throw SessionRenewalError.failed }
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let id = object["id"] as? Int else { continue }
                    guard object["error"] == nil else { throw SessionRenewalError.failed }
                    if id == 0 && !initialized {
                        guard object["result"] != nil else { throw SessionRenewalError.failed }
                        try send(["method": "initialized"], to: input)
                        try send(["id": 1, "method": "account/read", "params": ["refreshToken": true]], to: input)
                        initialized = true
                    } else if id == 1 && initialized {
                        let result = object["result"] as? [String: Any]
                        let account = result?["account"] as? [String: Any]
                        guard account?["type"] as? String == "chatgpt" else { throw SessionRenewalError.failed }
                        finished = true
                    }
                }
                if !finished {
                    // Drain the final response even when the process exits between reads.
                    guard process.isRunning || !observedExit else { throw SessionRenewalError.failed }
                    observedExit = !process.isRunning
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try outcome.get()
    }

    private static func send(_ object: [String: Any], to input: Pipe) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
}
