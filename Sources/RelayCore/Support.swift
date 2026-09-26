import Foundation

public enum RelayError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else { self = .array(try c.decode([JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON { get { object?[key] ?? .null } set { var o = object ?? [:]; o[key] = newValue; self = .object(o) } }
    public var object: [String: JSON]? { if case .object(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? { if case .number(let v) = self, v.isFinite, v >= 0, v < Double(Int.max) { return Int(v) }; return nil }
    public var array: [JSON]? { if case .array(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public init(data: Data) throws { self = try JSONDecoder().decode(JSON.self, from: data) }
}

public struct RelayPaths {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Profiles/Remote")
    }
    public var identity: URL { root.appendingPathComponent("Identity", isDirectory: true) }
    public var socket: URL { root.appendingPathComponent("run/runtime.sock") }
    public var runtimePID: URL { root.appendingPathComponent("run/runtime.pid") }
    public var cliCandidates: [String] {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["CODEX_PROFILES_CLI"],
           FileManager.default.isExecutableFile(atPath: path) { candidates.append(path) }
        candidates += ["/Applications/ChatGPT.app", "/Applications/Codex.app"].flatMap { app in
            [
                app + "/Contents/Resources/codex-cli/bin/codex",
                app + "/Contents/Resources/codex-cli/bin/../CodexCLI.app/Contents/MacOS/codex",
                app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                app + "/Contents/Resources/codex",
            ]
        }
        return candidates
    }
    public var cli: String {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
    }
    public func prepare() throws {
        for url in [root, identity, socket.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        guard socket.path.utf8.count < 104 else { throw RelayError.message("Relay socket path is too long.") }
    }
    public static func privateWrite(_ data: Data, to url: URL) throws {
        // Use a private sibling before rename; never leave a world-readable credential window.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw RelayError.message("Could not save settings.") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if rename(temporary.path, url.path) != 0 { throw RelayError.message("Could not update settings.") }
    }
}

/// Private local storage, matching Codex's file-based credential mode.
public enum Vault {
    private static func file(_ key: String, paths: RelayPaths) throws -> URL {
        guard ["phone-account", "enrollment"].contains(key) else { throw RelayError.message("Unknown credential key.") }
        try paths.prepare()
        return paths.root.appendingPathComponent(key + ".json")
    }
    public static func put(_ data: Data, key: String, paths: RelayPaths = RelayPaths()) throws {
        try RelayPaths.privateWrite(data, to: file(key, paths: paths))
    }
    public static func get(_ key: String, paths: RelayPaths = RelayPaths()) throws -> Data? {
        let url = try file(key, paths: paths)
        if FileManager.default.fileExists(atPath: url.path) { let data = try Data(contentsOf: url); return data.isEmpty ? nil : data }
        if key == "phone-account" {
            let auth = paths.identity.appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: auth.path) {
                let data = try Data(contentsOf: auth); try put(data, key: key, paths: paths); return data
            }
        }
        return nil
    }
    public static func remove(_ key: String, paths: RelayPaths = RelayPaths()) {
        // A tombstone prevents the Codex working copy from restoring a signed-out account.
        if let url = try? file(key, paths: paths) { try? RelayPaths.privateWrite(Data(), to: url) }
    }
}

public struct AccountProfile {
    public let auth: Data
    public let accountID: String
    public let email: String
    public init(data: Data) throws {
        let value = try JSON(data: data)
        let raw: Data
        if let profiles = value["profiles"].array {
            guard profiles.count == 1, let text = profiles.first?["authJSONString"].string else { throw RelayError.message("Export one account for your phone.") }
            raw = Data(text.utf8)
        } else { raw = data }
        let auth = try JSON(data: raw)
        guard let id = auth["tokens"]["account_id"].string, !id.isEmpty,
              let token = auth["tokens"]["access_token"].string, !token.isEmpty,
              token.utf8.count < 32768 else { throw RelayError.message("Choose a ChatGPT .codexprofile.json or auth.json file.") }
        self.auth = raw; accountID = id
        let claims = Self.claims(auth["tokens"]["id_token"].string ?? "")
        email = claims["email"].string ?? "ChatGPT account"
    }
    public static func claims(_ token: String) -> JSON {
        let parts = token.split(separator: "."); guard parts.count == 3 else { return .null }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded: s) else { return .null }; return (try? JSON(data: d)) ?? .null
    }
}
