import Foundation
import Darwin

enum RenewalPreferences {
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "renew_inactive_sessions") as? Bool ?? true
    }

    static func leadDays(in defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: "renewal_lead_days") as? Int ?? 1
        return min(7, max(1, value))
    }
}

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
        let mode = json["auth_mode"] as? String
        isManaged = apiKey.isEmpty && (mode == nil || mode == "chatgpt") && refreshToken != nil
    }

    func scheduledRenewal(lastAttempt: Date?, leadDays: Int = 1) -> Date? {
        guard isManaged, let expiresAt else { return nil }
        let due = expiresAt.addingTimeInterval(-Double(min(7, max(1, leadDays))) * 86_400)
        return lastAttempt.map { max(due, $0.addingTimeInterval(86_400)) } ?? due
    }

    func needsRenewal(now: Date, lastAttempt: Date?, leadDays: Int = 1) -> Bool {
        scheduledRenewal(lastAttempt: lastAttempt, leadDays: leadDays).map { $0 <= now } ?? false
    }

    static func credentialsChanged(from previous: Data, to renewed: Data) -> Bool {
        let old = ((try? JSONSerialization.jsonObject(with: previous)) as? [String: Any])?["tokens"] as? [String: Any]
        let new = ((try? JSONSerialization.jsonObject(with: renewed)) as? [String: Any])?["tokens"] as? [String: Any]
        return old?["access_token"] as? String != new?["access_token"] as? String
            || old?["refresh_token"] as? String != new?["refresh_token"] as? String
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
    case unavailable, active, shared, failed, timeout, unchanged, signInRequired, accessExpired

    static func classify(_ object: Any) -> SessionRenewalError {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
        let message = String(decoding: data, as: UTF8.self).lowercased()
        let permanent = ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
                         "refresh token has expired", "refresh token was already used", "refresh token was revoked"]
        return permanent.contains(where: message.contains) ? .signInRequired : .failed
    }

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "This session can no longer be renewed. Sign in again; automatic retries are paused."
        case .accessExpired: return "Renew this session before checking limits. If renewal fails, sign in again."
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
        let result = try await request(executable: executable, home: home, timeout: timeout,
                                       requests: [("account/read", ["refreshToken": true])], verifyRenewal: true)
        guard (result["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
            throw SessionRenewalError.failed
        }
    }

    /// External access-token mode prevents a usage check from rotating shared refresh tokens.
    static func limits(executable: URL, auth: Data) async throws -> UsageSnapshot {
        let metadata = SessionMetadata(data: auth)
        guard let expiry = metadata.expiresAt, expiry > Date() else { throw SessionRenewalError.accessExpired }
        let json = (try? JSONSerialization.jsonObject(with: auth)) as? [String: Any]
        guard let tokens = json?["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty else { throw SessionRenewalError.unavailable }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try await request(executable: executable, home: home, requests: [
            ("account/login/start", ["type": "chatgptAuthTokens", "accessToken": access, "chatgptAccountId": account]),
            ("account/rateLimits/read", [:])
        ], experimental: true)
        return UsageSnapshot.parse(result)
    }

    private static func request(executable: URL, home: URL, timeout: TimeInterval = 30,
                                requests: [(String, [String: Any])], experimental: Bool = false,
                                verifyRenewal: Bool = false) async throws -> [String: Any] {
        var queued = requests
        let previousAuth = verifyRenewal ? try? Data(contentsOf: home.appendingPathComponent("auth.json")) : nil
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
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        try process.run()
        let outcome: Result<[String: Any], Error>
        do {
            try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "codex_profiles", "title": "Codex Profiles", "version": "1.13"], "capabilities": ["experimentalApi": experimental]]], to: input)
            var pending = Data()
            var totalBytes = 0
            var initialized = false
            var finished = false
            var observedExit = false
            var requestIndex = 0
            var response: [String: Any] = [:]
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
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if object["method"] as? String == "account/chatgptAuthTokens/refresh" {
                        throw SessionRenewalError.accessExpired
                    }
                    guard let id = object["id"] as? Int else { continue }
                    if let error = object["error"] { throw SessionRenewalError.classify(error) }
                    if id == 0 && !initialized {
                        guard object["result"] != nil else { throw SessionRenewalError.failed }
                        try send(["method": "initialized"], to: input)
                        try send(["id": 1, "method": queued[0].0, "params": queued[0].1], to: input)
                        initialized = true
                    } else if id == requestIndex + 1 && initialized {
                        guard let result = object["result"] as? [String: Any] else { throw SessionRenewalError.failed }
                        if queued[requestIndex].0 == "getAuthStatus" {
                            // account/read can swallow refresh errors. The compatibility endpoint
                            // suppresses authToken for a confirmed permanent refresh failure.
                            // Never display, persist, or log that token.
                            if result["authMethod"] as? String == "chatgpt", result["authToken"] is NSNull {
                                throw SessionRenewalError.signInRequired
                            }
                        } else {
                            response = result
                        }
                        if verifyRenewal && requestIndex == 0, let previousAuth,
                           let latest = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
                           !SessionMetadata.credentialsChanged(from: previousAuth, to: latest) {
                            queued.append(("getAuthStatus", ["includeToken": true, "refreshToken": false]))
                        }
                        requestIndex += 1
                        finished = requestIndex == queued.count
                        if !finished {
                            try send(["id": requestIndex + 1, "method": queued[requestIndex].0, "params": queued[requestIndex].1], to: input)
                        }
                    }
                }
                if !finished {
                    // Drain the final response even when the process exits between reads.
                    guard process.isRunning || !observedExit else { throw SessionRenewalError.failed }
                    observedExit = !process.isRunning
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            outcome = .success(response)
        } catch { outcome = .failure(error) }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return try outcome.get()
    }

    private static func send(_ object: [String: Any], to input: Pipe) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
}
