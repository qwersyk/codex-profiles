import Foundation

public struct StreamKey: Hashable, Sendable {
    public let client: String
    public let stream: String
    public init(client: String, stream: String) { self.client = client; self.stream = stream }
}
/// Bounded framing and deduplication. Cursor advances only after a complete message is delivered.
public struct ChunkAssembler {
    struct Assembly { var sequence: Int; var count: Int; var size: Int; var chunks: [Int: Data]; var bytes: Int; var created: Date }
    private var assemblies: [StreamKey: Assembly] = [:]
    public init() {}
    public mutating func accept(_ envelope: JSON, key: StreamKey) throws -> JSON? {
        let now = Date(); assemblies = assemblies.filter { now.timeIntervalSince($0.value.created) < 60 }
        guard let seq = envelope["seq_id"].int, let index = envelope["segment_id"].int,
              let count = envelope["segment_count"].int, count > 0, count <= 1024, index < count,
              let size = envelope["message_size_bytes"].int, size > 0, size <= 32 * 1024 * 1024,
              let base64 = envelope["message_chunk_base64"].string, base64.utf8.count <= 150 * 1024,
              let data = Data(base64Encoded: base64), !data.isEmpty else { throw RelayError.message("Invalid Remote fragment.") }
        if assemblies[key] == nil {
            guard assemblies.count < 8 else { throw RelayError.message("Too many incomplete messages.") }
            assemblies[key] = Assembly(sequence: seq, count: count, size: size, chunks: [:], bytes: 0, created: now)
        }
        guard var a = assemblies[key], a.sequence == seq, a.count == count, a.size == size else {
            assemblies.removeValue(forKey: key); throw RelayError.message("Invalid Remote fragment order.")
        }
        if let prior = a.chunks[index] {
            guard prior == data else { assemblies.removeValue(forKey: key); throw RelayError.message("Conflicting fragment replay.") }
            return nil
        }
        a.chunks[index] = data; a.bytes += data.count
        guard a.bytes <= size else { assemblies.removeValue(forKey: key); throw RelayError.message("Message size exceeded.") }
        assemblies[key] = a
        guard a.chunks.count == count else { return nil }
        assemblies.removeValue(forKey: key)
        guard a.bytes == size else { throw RelayError.message("Incomplete Remote message.") }
        var joined = Data(); joined.reserveCapacity(size)
        for i in 0..<count { joined.append(a.chunks[i]!) }
        return try JSON(data: joined)
    }
    public mutating func remove(_ key: StreamKey) { assemblies.removeValue(forKey: key) }
}

public struct OutboundFrame {
    public let key: StreamKey
    public let sequence: Int
    public let segment: Int?
    public let data: Data
}
public enum WireProtocol {
    public static func frames(message: JSON, key: StreamKey, sequence: Int) throws -> [OutboundFrame] {
        var base: JSON = .object(["type": .string("server_message"), "client_id": .string(key.client), "stream_id": .string(key.stream), "seq_id": .number(Double(sequence)), "message": message])
        let full = try base.data()
        if full.count <= 150 * 1024 { return [OutboundFrame(key: key, sequence: sequence, segment: nil, data: full)] }
        let data = try message.data(); guard data.count <= 32 * 1024 * 1024 else { throw RelayError.message("Message exceeds 32 MB.") }
        let length = 100 * 1024, count = (data.count + length - 1) / length
        base = .object(["type": .string("server_message_chunk"), "client_id": .string(key.client), "stream_id": .string(key.stream), "seq_id": .number(Double(sequence)), "segment_count": .number(Double(count)), "message_size_bytes": .number(Double(data.count))])
        return try (0..<count).map { i in
            var e = base; e["segment_id"] = .number(Double(i))
            e["message_chunk_base64"] = .string(data.subdata(in: i * length..<min((i + 1) * length, data.count)).base64EncodedString())
            return OutboundFrame(key: key, sequence: sequence, segment: i, data: try e.data())
        }
    }
    public static func isAcknowledged(_ frame: OutboundFrame, key: StreamKey, sequence: Int, segment: Int?) -> Bool {
        guard frame.key == key else { return false }
        return frame.sequence < sequence || (frame.sequence == sequence && (frame.segment ?? 0) <= (segment ?? Int.max))
    }
    /// These operations are local-only or expose authentication secrets. They are never proxied from a phone.
    public static func permits(_ method: String) -> Bool {
        if method.hasPrefix("userVerification/") { return method == "userVerification/status" }
        if method.hasPrefix("account/") { return ["account/read", "account/rateLimits/read"].contains(method) }
        if method.hasPrefix("remoteControl/") { return false }
        return !["getAuthStatus", "loginApiKey", "loginChatGpt", "cancelLoginChatGpt", "logoutChatGpt", "getAccount", "login", "logout"].contains(method)
    }
}

public struct Outbox {
    public private(set) var frames: [OutboundFrame] = []
    public private(set) var bytes = 0
    public let limit: Int
    public init(limit: Int = 48 * 1024 * 1024) { self.limit = limit }
    public mutating func append(_ added: [OutboundFrame]) throws {
        let size = added.reduce(0) { $0 + $1.data.count }
        guard bytes + size <= limit, frames.count + added.count <= 8192 else { throw RelayError.message("Phone is not receiving data. Reconnect Remote.") }
        frames += added; bytes += size
    }
    public mutating func acknowledge(key: StreamKey, sequence: Int, segment: Int?) {
        frames.removeAll { f in
            if WireProtocol.isAcknowledged(f, key: key, sequence: sequence, segment: segment) { bytes -= f.data.count; return true }; return false
        }
    }
    public mutating func remove(_ key: StreamKey) { frames.removeAll { f in if f.key == key { bytes -= f.data.count; return true }; return false } }
}
