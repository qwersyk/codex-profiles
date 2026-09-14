import Foundation

struct UsageWindow: Codable, Equatable, Identifiable {
    let id: String
    let bucket: String
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    var durationLabel: String {
        guard let minutes = durationMinutes else { return "Usage" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct UsageSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let windows: [UsageWindow]

    static func parse(_ result: [String: Any], now: Date = Date()) -> UsageSnapshot {
        var buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if buckets.isEmpty, let legacy = result["rateLimits"] as? [String: Any] {
            buckets[legacy["limitId"] as? String ?? "codex"] = legacy
        }
        var windows: [UsageWindow] = []
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] else { continue }
            let name = bucket["limitName"] as? String ?? key
            for kind in ["primary", "secondary"] {
                guard let value = bucket[kind] as? [String: Any],
                      let used = value["usedPercent"] as? Double, used.isFinite else { continue }
                let duration = (value["windowDurationMins"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) }
                    .flatMap { $0 > 0 ? $0 : nil }
                let reset = (value["resetsAt"] as? Double).flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                windows.append(UsageWindow(id: key + ":" + kind, bucket: String(name.prefix(80)),
                                           usedPercent: max(0, min(100, used)), durationMinutes: duration, resetsAt: reset))
            }
        }
        return UsageSnapshot(fetchedAt: now, windows: windows)
    }
}

struct SessionOverview {
    var plan: String?
    var expiresAt: Date?
    var nextAttempt: Date?
    var requiresSignIn = false
    var renewalFailed = false
    var lastAttempt: Date?
    var usage: UsageSnapshot?
}
