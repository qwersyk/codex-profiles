import Foundation

@MainActor
enum SessionRenewalTests {
    static func auth(_ account: String, expires: Date, refresh: String = "refresh-fixture", plan: String = "plus") throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "exp": expires.timeIntervalSince1970,
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan]
        ]).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": [
            "account_id": account, "access_token": "header." + payload + ".signature", "refresh_token": refresh
        ]])
    }

    static func run() async throws {
        let suite = ProfileStoreTests()
        try suite.setUpWithError()
        defer { try? suite.tearDownWithError() }
        let now = Date()
        let preferencesName = "CodexProfilesTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        XCTAssertEqual(RenewalPreferences.isEnabled(in: preferences), true)
        XCTAssertEqual(RenewalPreferences.leadDays(in: preferences), 1)
        preferences.set(false, forKey: "renew_inactive_sessions")
        XCTAssertEqual(RenewalPreferences.isEnabled(in: preferences), false)
        preferences.set(100, forKey: "renewal_lead_days")
        XCTAssertEqual(RenewalPreferences.leadDays(in: preferences), 7)
        preferences.set(-5, forKey: "renewal_lead_days")
        XCTAssertEqual(RenewalPreferences.leadDays(in: preferences), 1)
        let withinThreeDays = SessionMetadata(data: try auth("scheduled", expires: now.addingTimeInterval(2 * 86_400)))
        XCTAssertEqual(withinThreeDays.needsRenewal(now: now, lastAttempt: nil, leadDays: 1), false)
        XCTAssertEqual(withinThreeDays.needsRenewal(now: now, lastAttempt: nil, leadDays: 3), true)
        XCTAssertEqual(withinThreeDays.needsRenewal(now: now, lastAttempt: now, leadDays: 7), false)
        print("PASS: Default renewal, explicit opt-out, configurable lead time, and backoff")
        let original = try auth("session", expires: now.addingTimeInterval(3600))
        _ = try suite.store.importFile(from: suite.file(original), fallbackIndex: 1)
        let id = try suite.store.loadProfiles()[0].id
        XCTAssertEqual(suite.store.sessionMetadata(id: id)?.plan, "Plus")
        XCTAssertEqual(suite.store.nextRenewalID(now: now), id)
        try suite.store.recordRenewal(id: id, status: "Failed safely", now: now)
        XCTAssertEqual(suite.store.nextRenewalID(now: now.addingTimeInterval(3600)), nil)
        XCTAssertEqual(suite.store.nextRenewalID(now: now.addingTimeInterval(86_401)), id)
        XCTAssertEqual(SessionMetadata(data: try auth("fresh", expires: now.addingTimeInterval(10 * 86_400))).needsRenewal(now: now, lastAttempt: nil), false)
        XCTAssertEqual(SessionMetadata(data: try auth("unknown", expires: now, plan: "unexpected-secret")).plan, nil)
        XCTAssertEqual(suite.store.sessionDetails(id: id).contains("Billing dates are unavailable"), true)
        print("PASS: Plan parsing and renewal backoff")
        try suite.store.recordRenewal(id: id, status: "Check connection", now: now, failed: true)
        _ = try suite.store.importFile(from: suite.file(original), fallbackIndex: 1)
        XCTAssertEqual(try suite.store.loadProfiles()[0].renewalFailed, true)
        XCTAssertEqual(suite.store.nextRenewalID(now: now), nil)
        print("PASS: Reimporting unchanged credentials preserves renewal status and backoff")

        let currentAuth = suite.home.appendingPathComponent("auth.json")
        try original.write(to: currentAuth)
        XCTAssertThrowsError(try suite.store.renewalHome(id: id))
        XCTAssertEqual(suite.store.nextRenewalID(now: now.addingTimeInterval(86_401)), nil)
        try auth("other-workspace", expires: now).write(to: currentAuth)
        XCTAssertThrowsError(try suite.store.renewalHome(id: id))
        try FileManager.default.removeItem(at: currentAuth)
        print("PASS: Renewal skips active accounts and shared refresh tokens")

        let sessionHome = try suite.store.renewalHome(id: id)
        let renewed = try auth("session", expires: now.addingTimeInterval(10 * 86_400), refresh: "rotated-fixture")
        try renewed.write(to: sessionHome.appendingPathComponent("renewed-fixture.json"))
        let executable = try script(suite, """
        [[ "$1" == app-server && "${PWD:A}" == "${CODEX_HOME:A}" && -z "$OPENAI_API_KEY" ]] || exit 2
        IFS= read -r request
        [[ "$request" == *initialize* ]] || exit 3
        print -r -- '{"id":0,"result":{"userAgent":"fixture"}}'
        IFS= read -r request
        [[ "$request" == *initialized* ]] || exit 4
        IFS= read -r request
        [[ "$request" == *account*read* && "$request" == *'"refreshToken":true'* ]] || exit 5
        /bin/cp "$CODEX_HOME/renewed-fixture.json" "$CODEX_HOME/auth.json"
        print -r -- '{"id":1,"result":{"account":{"type":"chatgpt","planType":"plus"}}}'
        """)
        try await SessionRenewal.renew(executable: executable, home: sessionHome)
        try suite.store.completeRenewal(id: id, previous: original)
        XCTAssertEqual(try suite.store.loadProfiles()[0].renewalFailed, false)
        XCTAssertEqual(try Data(contentsOf: sessionHome.appendingPathComponent("auth.json")), renewed)
        XCTAssertEqual(FileManager.default.fileExists(atPath: currentAuth.path), false)
        XCTAssertEqual(suite.store.nextRenewalID(), nil)
        XCTAssertThrowsError(try suite.store.completeRenewal(id: id, previous: renewed))
        var metadataOnly = try JSONSerialization.jsonObject(with: renewed) as! [String: Any]
        metadataOnly["last_refresh"] = "2099-01-01T00:00:00Z"
        try JSONSerialization.data(withJSONObject: metadataOnly).write(to: sessionHome.appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try suite.store.completeRenewal(id: id, previous: renewed))
        try renewed.write(to: sessionHome.appendingPathComponent("auth.json"))
        print("PASS: Official refresh protocol, rotation, and unchanged-token detection")

        let failing = try script(suite, """
        IFS= read -r request
        /bin/cp "$CODEX_HOME/renewed-fixture.json" "$CODEX_HOME/auth.json"
        print -r -- '{"id":0,"error":{"message":"secret-must-not-leak"}}'
        """)
        try original.write(to: sessionHome.appendingPathComponent("auth.json"))
        do {
            try await SessionRenewal.renew(executable: failing, home: sessionHome)
            preconditionFailure("Expected failure")
        } catch { XCTAssertEqual(error.localizedDescription.contains("secret-must-not-leak"), false) }
        XCTAssertEqual(try Data(contentsOf: sessionHome.appendingPathComponent("auth.json")), renewed)
        let hanging = try script(suite, "exec /bin/sleep 30")
        let start = Date()
        do {
            try await SessionRenewal.renew(executable: hanging, home: sessionHome, timeout: 0.2)
            preconditionFailure("Expected timeout")
        } catch { XCTAssertEqual(error as? SessionRenewalError == .timeout, true) }
        precondition(Date().timeIntervalSince(start) < 5)
        print("PASS: Failed response and timeout preserve credentials without exposing secrets")

        XCTAssertEqual(SessionRenewalError.classify(["message": "Your refresh token was already used."]), .signInRequired)
        XCTAssertEqual(SessionRenewalError.classify(["message": "Connection timed out"]), .failed)
        let dead = try script(suite, """
        IFS= read -r request
        print -r -- '{"id":0,"result":{}}'
        IFS= read -r request
        IFS= read -r request
        print -r -- '{"id":1,"result":{"account":{"type":"chatgpt"}}}'
        IFS= read -r request
        [[ "$request" == *getAuthStatus* ]] || exit 6
        print -r -- '{"id":2,"result":{"authMethod":"chatgpt","authToken":null,"requiresOpenaiAuth":true}}'
        """)
        do {
            try await SessionRenewal.renew(executable: dead, home: sessionHome)
            preconditionFailure("Expected permanent failure")
        } catch { XCTAssertEqual(error as? SessionRenewalError, .signInRequired) }
        try suite.store.recordRenewal(id: id, status: "Sign in again", failed: true, requiresSignIn: true)
        XCTAssertEqual(suite.store.nextRenewalID(now: now.addingTimeInterval(30 * 86_400)), nil)
        XCTAssertThrowsError(try suite.store.renewalHome(id: id))
        _ = try suite.store.importFile(from: suite.file(renewed), fallbackIndex: 1)
        XCTAssertEqual(try suite.store.loadProfiles()[0].renewalRequiresSignIn, true)
        let newLogin = try auth("session", expires: now.addingTimeInterval(20 * 86_400), refresh: "new-login")
        _ = try suite.store.importFile(from: suite.file(newLogin), fallbackIndex: 1)
        XCTAssertEqual(try suite.store.loadProfiles()[0].renewalRequiresSignIn, nil)
        print("PASS: Permanent failures stop retries until new credentials arrive")

        let parsed = UsageSnapshot.parse([
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": [
                "primary": ["usedPercent": 25.0, "windowDurationMins": 300, "resetsAt": now.timeIntervalSince1970 + 600],
                "secondary": NSNull()
            ], "other": ["primary": ["windowDurationMins": 20]]]
        ], now: now)
        XCTAssertEqual(parsed.windows.count, 1)
        XCTAssertEqual(parsed.windows[0].remainingPercent, 75)
        XCTAssertEqual(parsed.windows[0].durationLabel, "5h")
        XCTAssertEqual(UsageSnapshot.parse([:]).windows.count, 0)
        let dual = UsageSnapshot.parse([
            "rateLimitResetCredits": ["availableCount": 2],
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 40, "windowDurationMins": 300],
                          "secondary": ["usedPercent": 70, "windowDurationMins": 10080]],
                "other": ["primary": ["usedPercent": 99, "windowDurationMins": 1]]
            ]
        ])
        XCTAssertEqual(dual.availableResets, 2)
        XCTAssertEqual(dual.indicatorWindows.count, 2)
        XCTAssertEqual(dual.indicatorWindows.first?.remainingPercent, 60)
        XCTAssertEqual(dual.indicatorWindows.last?.remainingPercent, 30)
        XCTAssertEqual(parsed.indicatorWindows.count, 1)
        XCTAssertEqual(parsed.availableResets, nil)
        let oldCache = Data("{\"fetchedAt\":0,\"windows\":[]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: oldCache).availableResets, nil)
        try suite.store.saveUsage(id: id, snapshot: parsed)
        let cached = try suite.store.loadProfiles()[0].usage
        XCTAssertEqual(cached?.windows.count, 1)
        XCTAssertEqual(cached?.windows[0].remainingPercent, 75)
        precondition(abs(cached!.fetchedAt.timeIntervalSince(parsed.fetchedAt)) < 1)
        for duration in [300, 10080, 43200] {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let reset = start.addingTimeInterval(Double(duration) * 60)
            let window = UsageWindow(id: "reset", bucket: "codex", usedPercent: 25,
                                     durationMinutes: duration, resetsAt: reset)
            XCTAssertEqual(window.resetProgress(at: start), 0)
            XCTAssertEqual(window.resetProgress(at: start.addingTimeInterval(Double(duration) * 30)), 0.5)
            XCTAssertEqual(window.resetProgress(at: reset.addingTimeInterval(10)), 1)
            XCTAssertEqual(window.resetProgress(at: start.addingTimeInterval(-10)), 0)
            XCTAssertEqual(window.resetCountdown(at: reset), "Reset due")
            XCTAssertEqual(window.resetCountdown(at: reset.addingTimeInterval(-90)), "Reset in 2m")
        }
        let unknownReset = UsageWindow(id: "unknown", bucket: "codex", usedPercent: 0,
                                       durationMinutes: nil, resetsAt: nil)
        XCTAssertEqual(unknownReset.resetProgress(at: Date()), nil)
        XCTAssertEqual(unknownReset.resetCountdown(at: Date()), nil)
        print("PASS: Usage buckets, missing windows, remaining percentage, and cache")

        let usageCLI = try script(suite, """
        [[ ! -e "$CODEX_HOME/auth.json" ]] || exit 2
        IFS= read -r request
        [[ "$request" == *'"experimentalApi":true'* ]] || exit 3
        print -r -- '{"id":0,"result":{}}'
        IFS= read -r request
        IFS= read -r request
        [[ "$request" == *chatgptAuthTokens* && "$request" != *refresh_token* ]] || exit 4
        print -r -- '{"id":1,"result":{"type":"chatgptAuthTokens"}}'
        IFS= read -r request
        [[ "$request" == *account*rateLimits*read* ]] || exit 5
        print -r -- '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}'
        """)
        let usage = try await SessionRenewal.limits(executable: usageCLI, auth: newLogin)
        XCTAssertEqual(usage.windows[0].remainingPercent, 75)
        XCTAssertEqual(try Data(contentsOf: sessionHome.appendingPathComponent("auth.json")), newLogin)
        do {
            _ = try await SessionRenewal.limits(executable: usageCLI, auth: auth("expired", expires: now.addingTimeInterval(-1)))
            preconditionFailure("Expired access token should not be sent")
        } catch { XCTAssertEqual(error as? SessionRenewalError, .accessExpired) }
        print("PASS: Usage reads use isolated access-only auth without rotating saved sessions")
    }

    private static func script(_ suite: ProfileStoreTests, _ body: String) throws -> URL {
        let url = try suite.file(Data(("#!/bin/zsh\n" + body + "\n").utf8), name: UUID().uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
