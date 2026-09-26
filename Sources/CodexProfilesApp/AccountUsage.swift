import Foundation

struct UsageWindow: Codable, Equatable, Identifiable {
    let id: String
    let bucket: String
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    func resetProgress(at date: Date) -> Double? {
        guard let minutes = durationMinutes, minutes > 0, let reset = resetsAt,
              reset.timeIntervalSince1970.isFinite else { return nil }
        let duration = Double(minutes) * 60
        return max(0, min(1, 1 - reset.timeIntervalSince(date) / duration))
    }

    func resetCountdown(at date: Date) -> String? {
        guard let reset = resetsAt, reset.timeIntervalSince1970.isFinite else { return nil }
        let seconds = reset.timeIntervalSince(date)
        guard seconds > 0 else { return "Reset due" }
        let minutes = ceil(seconds / 60)
        guard minutes < Double(Int.max) else { return "Reset time unavailable" }
        if minutes >= 1440 {
            return "Reset in \(Int(minutes / 1440))d \(Int(minutes.truncatingRemainder(dividingBy: 1440) / 60))h"
        }
        if minutes >= 60 {
            return "Reset in \(Int(minutes / 60))h \(Int(minutes.truncatingRemainder(dividingBy: 60)))m"
        }
        return "Reset in \(Int(minutes))m"
    }

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

    var availableResets: Int? = nil

    var indicatorWindows: [UsageWindow] {
        let key = windows.first(where: { $0.id.hasPrefix("codex:") })?.id.components(separatedBy: ":").first
            ?? windows.first?.id.components(separatedBy: ":").first
        return windows.filter { $0.id.components(separatedBy: ":").first == key }
            .sorted { ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max) }
    }

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 3600 || windows.contains { ($0.resetsAt ?? .distantFuture) <= Date() }
    }

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
                      let used = (value["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
                let duration = (value["windowDurationMins"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) }
                    .flatMap { $0 > 0 ? $0 : nil }
                let reset = (value["resetsAt"] as? Double).flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                windows.append(UsageWindow(id: key + ":" + kind, bucket: String(name.prefix(80)),
                                           usedPercent: max(0, min(100, used)), durationMinutes: duration, resetsAt: reset))
            }
        }
        let resets = (result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        return UsageSnapshot(fetchedAt: now, windows: windows, availableResets: resets.flatMap { $0 >= 0 ? $0 : nil })
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
