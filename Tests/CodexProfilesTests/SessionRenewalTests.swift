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
        XCTAssertEqual(try Data(contentsOf: sessionHome.appendingPathComponent("auth.json")), renewed)
        XCTAssertEqual(FileManager.default.fileExists(atPath: currentAuth.path), false)
        XCTAssertEqual(suite.store.nextRenewalID(), nil)
        XCTAssertThrowsError(try suite.store.completeRenewal(id: id, previous: renewed))
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
    }

    private static func script(_ suite: ProfileStoreTests, _ body: String) throws -> URL {
        let url = try suite.file(Data(("#!/bin/zsh\n" + body + "\n").utf8), name: UUID().uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
