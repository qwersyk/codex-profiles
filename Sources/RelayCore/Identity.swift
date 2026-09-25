import Foundation

/// Reads the selected saved session; Codex Profiles owns all token renewal.
@MainActor public final class PhoneIdentity {
    public let paths: RelayPaths
    public private(set) var profile: AccountProfile?
    public var credentialProvider: (() async throws -> Data)?
    public init(paths: RelayPaths) { self.paths = paths }
    public func useSavedProfile(_ data: Data) throws { profile = try AccountProfile(data: data) }
    public func credentials() async throws -> (token: String, accountID: String) {
        guard let profile, let credentialProvider else { throw RelayError.message("Choose the account used on your phone.") }
        let current = try AccountProfile(data: await credentialProvider())
        try Task.checkCancellation()
        guard current.accountID == profile.accountID else { throw RelayError.message("Select the phone account again.") }
        self.profile = current
        let auth = try JSON(data: current.auth)
        return (auth["tokens"]["access_token"].string!, current.accountID)
    }
}

public struct Enrollment: Codable {
    public let serverID: String
    public let environmentID: String
    public let token: String
    public let expires: Date
    public let accountID: String
}
public struct Pairing: Equatable {
    public let code: String
    public let manualCode: String?
    public let expires: Date
    public var url: URL {
        var u = URLComponents(string: "https://chatgpt.com/codex/pair")!
        u.queryItems = [URLQueryItem(name: "pairing_code", value: code)]; return u.url!
    }
}
public struct RemoteAPIError: LocalizedError {
    public let status: Int
    public let retryAfter: Double?
    public var errorDescription: String? {
        switch status {
        case 401: return "Phone session expired. Sign in again."
        case 403: return "Remote access denied. Check MFA and workspace access."
        case 404: return "Remote pairing is unavailable. Pair again."
        case 429: return "ChatGPT is busy. Relay will retry."
        default: return "Remote unavailable (HTTP \(status))."
        }
    }
}

@MainActor public final class RemoteAPI {
    private let identity: PhoneIdentity
    private let session: URLSession
    public let installationID: String
    public let name: String
    public private(set) var enrollment: Enrollment?
    private var enrollmentTask: Task<Enrollment, Error>?
    public init(identity: PhoneIdentity, installationID: String, name: String) {
        self.identity = identity; self.installationID = installationID; self.name = name
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    public func restore() throws {
        if let data = try Vault.get("enrollment", paths: identity.paths), let saved = try? JSONDecoder().decode(Enrollment.self, from: data), saved.accountID == identity.profile?.accountID { enrollment = saved }
    }
    private func post(_ path: String, _ body: JSON, token: String, account: String? = nil) async throws -> JSON {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/remote/control/\(path)")!)
        request.httpMethod = "POST"; request.httpBody = try body.data()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(installationID, forHTTPHeaderField: "x-codex-installation-id")
        if let account { request.setValue(account, forHTTPHeaderField: "chatgpt-account-id") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RelayError.message("Invalid Remote response.") }
        guard (200..<300).contains(response.statusCode) else { throw RemoteAPIError(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)) }
        guard data.count <= 1_048_576 else { throw RelayError.message("Remote response is too large.") }
        return try JSON(data: data)
    }
    public func ensureEnrollment(forceRefresh: Bool = false) async throws -> Enrollment {
        if let task = enrollmentTask { return try await task.value }
        let task = Task { try await self.loadEnrollment(forceRefresh: forceRefresh) }
        enrollmentTask = task
        defer { enrollmentTask = nil }
        return try await task.value
    }
    private func loadEnrollment(forceRefresh: Bool) async throws -> Enrollment {
        if let e = enrollment, e.accountID == identity.profile?.accountID, !forceRefresh, e.expires > Date().addingTimeInterval(300) { return e }
        let c = try await identity.credentials()
        let old = enrollment.flatMap { $0.accountID == c.accountID ? $0 : nil }
        let body: JSON = old.map { .object(["server_id": .string($0.serverID), "installation_id": .string(installationID)]) } ?? .object([
            "name": .string(name), "os": .string("macos"), "arch": .string("aarch64"),
            "app_server_version": .string("0.155.0-alpha.16.4"), "installation_id": .string(installationID)
        ])
        let result = try await post(old == nil ? "server/enroll" : "server/refresh", body, token: c.token, account: c.accountID)
        guard let server = result["server_id"].string, let env = result["environment_id"].string, let token = result["remote_control_token"].string, let expires = Self.date(result["expires_at"].string) else { throw RelayError.message("Remote protocol has changed.") }
        let value = Enrollment(serverID: server, environmentID: env, token: token, expires: expires, accountID: c.accountID)
        try Task.checkCancellation()
        try Vault.put(JSONEncoder().encode(value), key: "enrollment", paths: identity.paths); enrollment = value; return value
    }
    public func pair() async throws -> Pairing {
        let e = try await ensureEnrollment()
        let r = try await post("server/pair", .object(["manual_code": .bool(true)]), token: e.token)
        guard r["server_id"].string == e.serverID, r["environment_id"].string == e.environmentID,
              let code = r["pairing_code"].string, let expires = Self.date(r["expires_at"].string) else { throw RelayError.message("Pairing response does not match Relay.") }
        return Pairing(code: code, manualCode: r["manual_pairing_code"].string, expires: expires)
    }
    public func claimed(_ pairing: Pairing) async throws -> Bool {
        let e = try await ensureEnrollment()
        let r = try await post("server/pair/status", .object(["pairing_code": .string(pairing.code)]), token: e.token)
        return r["claimed"].bool == true
    }
    public func cancelPendingEnrollment() { enrollmentTask?.cancel() }
    public func resetLocalEnrollment() { enrollment = nil; Vault.remove("enrollment", paths: identity.paths) }
    public func socketRequest(_ e: Enrollment, cursor: String?) -> URLRequest {
        var r = URLRequest(url: URL(string: "wss://chatgpt.com/backend-api/wham/remote/control/server")!)
        r.setValue("Bearer \(e.token)", forHTTPHeaderField: "Authorization")
        r.setValue(e.serverID, forHTTPHeaderField: "x-codex-server-id")
        r.setValue(Data(name.utf8).base64EncodedString(), forHTTPHeaderField: "x-codex-name")
        r.setValue("3", forHTTPHeaderField: "x-codex-protocol-version")
        r.setValue(installationID, forHTTPHeaderField: "x-codex-installation-id")
        if let cursor { r.setValue(cursor, forHTTPHeaderField: "x-codex-subscribe-cursor") }; return r
    }
    public static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
