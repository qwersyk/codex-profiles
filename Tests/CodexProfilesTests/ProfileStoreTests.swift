import Foundation

func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "Values differ", file: file, line: line)
}
func XCTAssertThrowsError<T>(_ work: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try work() } catch { return }
    preconditionFailure("Expected error", file: file, line: line)
}

final class ProfileStoreTests {
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    var store: ProfileStore!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = ProfileStore(storageURL: root.appendingPathComponent("store"), codexHomeURL: home)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func auth(_ account: String, token: String = "initial") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": account, "access_token": token, "refresh_token": "refresh-" + token]])
    }
    func file(_ data: Data, name: String = "input.json") throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    func testArchiveRoundTrip() throws {
        _ = try store.importFile(from: file(auth("one")), fallbackIndex: 1)
        let exported = root.appendingPathComponent("backup.json")
        try store.exportAll(to: exported)
        XCTAssertEqual(try store.importFile(from: exported, fallbackIndex: 2), 1)
        XCTAssertEqual(try store.loadProfiles().count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: exported.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
    func testSwitchPreservesRotatedTokens() throws {
        let first = try auth("one")
        let second = try auth("two")
        _ = try store.importFile(from: file(first), fallbackIndex: 1)
        _ = try store.importFile(from: file(second), fallbackIndex: 2)
        let profiles = try store.loadProfiles()
        let rotated = try auth("one", token: "rotated")
        try rotated.write(to: home.appendingPathComponent("auth.json"))
        _ = try store.restoreProfile(id: profiles[1].id)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), second)
        _ = try store.restoreProfile(id: profiles[0].id)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), rotated)
    }
    func testInvalidImportDoesNotReplaceSavedProfile() throws {
        _ = try store.importFile(from: file(auth("one")), fallbackIndex: 1)
        XCTAssertThrowsError(try store.importFile(from: file(Data("{}".utf8)), fallbackIndex: 2))
        XCTAssertEqual(try store.loadProfiles().count, 1)
    }
    func testKeyringGuardDoesNotChangeAuth() throws {
        _ = try store.importFile(from: file(auth("one")), fallbackIndex: 1)
        let current = try auth("two")
        try current.write(to: home.appendingPathComponent("auth.json"))
        try Data("cli_auth_credentials_store = \"keyring\"".utf8).write(to: home.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try store.restoreProfile(id: store.loadProfiles()[0].id))
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), current)
    }
    func testFractionalDatesAndUnsupportedVersion() throws {
        let entry: [String: Any] = ["createdAt": "2026-09-02T20:41:51.123Z", "authJSONString": String(data: try auth("one"), encoding: .utf8)!]
        var archive: [String: Any] = ["format": "codex-profiles-archive", "version": 1, "exportedAt": "2026-09-02T20:41:58Z", "profiles": [entry]]
        XCTAssertEqual(try store.importFile(from: file(JSONSerialization.data(withJSONObject: archive)), fallbackIndex: 1), 1)
        archive["version"] = 99
        XCTAssertThrowsError(try store.importFile(from: file(JSONSerialization.data(withJSONObject: archive)), fallbackIndex: 1))
    }
    func testUnsavedOutgoingSessionIsPreserved() throws {
        _ = try store.importFile(from: file(auth("target")), fallbackIndex: 1)
        let target = try store.loadProfiles()[0].id
        let outgoing = try auth("unsaved")
        try outgoing.write(to: home.appendingPathComponent("auth.json"))
        _ = try store.restoreProfile(id: target)
        let profiles = try store.loadProfiles()
        XCTAssertEqual(profiles.count, 2)
        _ = try store.restoreProfile(id: profiles.first { $0.id != target }!.id)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), outgoing)
    }
    func testExportIncludesRefreshedCredentials() throws {
        _ = try store.importFile(from: file(auth("one")), fallbackIndex: 1)
        let rotated = try auth("one", token: "rotated")
        try rotated.write(to: home.appendingPathComponent("auth.json"))
        let destination = root.appendingPathComponent("export.json")
        try store.exportAll(to: destination)
        let archive = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: Any]
        let entry = (archive["profiles"] as! [[String: Any]])[0]
        XCTAssertEqual(Data((entry["authJSONString"] as! String).utf8), rotated)
    }
    func testLocalSignOutKeepsSessionRecoverable() throws {
        let current = try auth("local-signout")
        try current.write(to: home.appendingPathComponent("auth.json"))
        try store.signOutLocally()
        XCTAssertEqual(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path), false)
        let profiles = try store.loadProfiles()
        XCTAssertEqual(profiles.count, 1)
        _ = try store.restoreProfile(id: profiles[0].id)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), current)
    }
    func testLocalSignOutRefusesKeyring() throws {
        let current = try auth("keyring")
        try current.write(to: home.appendingPathComponent("auth.json"))
        try Data("cli_auth_credentials_store = \"keyring\"".utf8).write(to: home.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try store.signOutLocally())
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), current)
    }
    func datedAuth(_ date: String, token: String) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: auth("same", token: token)) as! [String: Any]
        object["last_refresh"] = date
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testOlderImportDoesNotDowngradeCredentials() throws {
        let recent = try datedAuth("2026-09-12T12:00:00Z", token: "new")
        let old = try datedAuth("2026-09-01T12:00:00Z", token: "old")
        _ = try store.importFile(from: file(recent), fallbackIndex: 1)
        _ = try store.importFile(from: file(old), fallbackIndex: 2)
        XCTAssertEqual(try store.loadProfiles().count, 1)
        _ = try store.restoreProfile(id: store.loadProfiles()[0].id)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), recent)
    }
    func testBackgroundSyncAndManualSaveDoNotDowngrade() throws {
        let recent = try datedAuth("2026-09-12T12:00:00.100Z", token: "new")
        let old = try datedAuth("2026-09-01T12:00:00Z", token: "old")
        _ = try store.importFile(from: file(recent), fallbackIndex: 1)
        try old.write(to: home.appendingPathComponent("auth.json"))
        try store.synchronizeSavedSession()
        _ = try store.captureCurrent(customName: nil, avatarSymbol: nil, avatarColorToken: nil, fallbackIndex: 1)
        _ = try store.restoreProfile(id: store.loadProfiles()[0].id)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("auth.json")), recent)
    }
    func testSessionDetailsDoNotContainTokens() throws {
        let marker = "secret-marker-never-display"
        _ = try store.importFile(from: file(auth("details", token: marker)), fallbackIndex: 1)
        let details = store.sessionDetails(id: try store.loadProfiles()[0].id)
        XCTAssertEqual(details.contains(marker), false)
        XCTAssertEqual(details.contains("Server validity has not been checked"), true)
    }
    func testUserSuppliedArchiveWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["PROFILE_TEST_IMPORT"] else { return }
        XCTAssertEqual(try store.importFile(from: URL(fileURLWithPath: path), fallbackIndex: 1), 1)
        XCTAssertEqual(try store.loadProfiles().count, 1)
    }
}

@main
struct TestRunner {
    @MainActor
    static func main() async throws {
        let suite = ProfileStoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("Archive round trip", suite.testArchiveRoundTrip),
            ("Rotated tokens survive switching", suite.testSwitchPreservesRotatedTokens),
            ("Invalid import preserves snapshots", suite.testInvalidImportDoesNotReplaceSavedProfile),
            ("Keyring guard preserves auth", suite.testKeyringGuardDoesNotChangeAuth),
            ("Date and version compatibility", suite.testFractionalDatesAndUnsupportedVersion),
            ("Unsaved outgoing session survives switching", suite.testUnsavedOutgoingSessionIsPreserved),
            ("Export preserves refreshed credentials", suite.testExportIncludesRefreshedCredentials),
            ("Local sign-out preserves session", suite.testLocalSignOutKeepsSessionRecoverable),
            ("Local sign-out respects keyring", suite.testLocalSignOutRefusesKeyring),
            ("Old import cannot downgrade tokens", suite.testOlderImportDoesNotDowngradeCredentials),
            ("Sync and save cannot downgrade tokens", suite.testBackgroundSyncAndManualSaveDoNotDowngrade),
            ("Session details omit secrets", suite.testSessionDetailsDoNotContainTokens),
            ("Optional local archive", suite.testUserSuppliedArchiveWhenRequested)
        ]
        for (name, test) in tests {
            if name == "Optional local archive", ProcessInfo.processInfo.environment["PROFILE_TEST_IMPORT"] == nil {
                print("SKIP: optional local archive (PROFILE_TEST_IMPORT not set)")
                continue
            }
            try suite.setUpWithError()
            do { try test() } catch {
                try? suite.tearDownWithError()
                throw error
            }
            try suite.tearDownWithError()
            print("PASS: \(name)")
        }
        try await SessionRenewalTests.run()
        try await RemoteTests.run()
    }
}
