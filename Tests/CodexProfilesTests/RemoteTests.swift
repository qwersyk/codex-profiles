import Foundation
import RelayCore
import Darwin

@MainActor enum RemoteTests {
    static func run() async throws {
        let key = StreamKey(client: "phone", stream: "one")
        let original = JSON.string(String(repeating: "Hello 👋", count: 40_000))
        let frames = try WireProtocol.frames(message: original, key: key, sequence: 1)
        var chunks = ChunkAssembler(), reconstructed: JSON?
        for frame in frames {
            var message = try JSON(data: frame.data); message["type"] = .string("client_message_chunk")
            reconstructed = try chunks.accept(message, key: key)
        }
        XCTAssertEqual(reconstructed, original)
        for method in ["account/login/start", "account/logout", "userVerification/verify"] {
            XCTAssertEqual(WireProtocol.permits(method), false)
        }
        print("PASS: Remote framing and account mutation isolation")
        let suite = ProfileStoreTests()
        try suite.setUpWithError()
        defer { try? suite.tearDownWithError() }
        let phone = try suite.auth("phone", token: "phone-original")
        let desktop = try suite.auth("desktop", token: "desktop-token")
        _ = try suite.store.importFile(from: suite.file(phone), fallbackIndex: 1)
        _ = try suite.store.importFile(from: suite.file(desktop), fallbackIndex: 2)
        let profiles = try suite.store.loadProfiles()
        let phoneID = profiles[0].id, desktopID = profiles[1].id
        let paths = RelayPaths(root: URL(fileURLWithPath: "/tmp/remote-test-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let identity = PhoneIdentity(paths: paths)
        try identity.useSavedProfile(phone)
        identity.credentialProvider = { try suite.store.usageAuth(id: phoneID) }
        _ = try suite.store.restoreProfile(id: desktopID)
        let first = try await identity.credentials()
        XCTAssertEqual(first.accountID, "phone")
        XCTAssertEqual(first.token, "phone-original")
        XCTAssertEqual(try Data(contentsOf: suite.home.appendingPathComponent("auth.json")), desktop)
        // A refreshed snapshot must be used directly, without an independent token copy.
        let fresh = try suite.auth("phone", token: "phone-refreshed")
        _ = try suite.store.importFile(from: suite.file(fresh), fallbackIndex: 3)
        let updated = try await identity.credentials()
        XCTAssertEqual(updated.token, "phone-refreshed")
        XCTAssertEqual(FileManager.default.fileExists(atPath: paths.identity.appendingPathComponent("auth.json").path), false)
        identity.credentialProvider = { desktop }
        do { _ = try await identity.credentials(); preconditionFailure("Wrong phone account accepted") }
        catch { }
        print("PASS: phone credentials remain independent across desktop switches and renewals")

        // A stale or tampered PID file must never terminate an unrelated process.
        try paths.prepare()
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        try RelayPaths.privateWrite(Data(String(sleeper.processIdentifier).utf8), to: paths.runtimePID)
        do { try await RuntimeProcess.stop(paths: paths); preconditionFailure("Unrelated process accepted") }
        catch { }
        XCTAssertEqual(sleeper.isRunning, true)
        print("PASS: runtime shutdown rejects unrelated processes")
        try await runtimeSwitch()
    }

    private static func runtimeSwitch() async throws {
        let paths = RelayPaths(root: URL(fileURLWithPath: "/tmp/r-switch-" + UUID().uuidString.prefix(8)))
        guard FileManager.default.isExecutableFile(atPath: paths.cli) else {
            print("SKIP: runtime switch requires installed ChatGPT"); return
        }
        try paths.prepare()
        let home = paths.root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var runtime: Process?
        defer {
            if let runtime, runtime.isRunning { runtime.terminate(); runtime.waitUntilExit() }
            try? FileManager.default.removeItem(at: paths.root)
        }
        func launch() async throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: paths.cli)
            process.arguments = ["app-server", "--listen", "unix://" + paths.socket.path]
            var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = home.path
            env.removeValue(forKey: "CODEX_CLI_PATH")
            process.environment = env
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); runtime = process
            try RelayPaths.privateWrite(Data(String(process.processIdentifier).utf8), to: paths.runtimePID)
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: paths.socket.path) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let channel = ProcessChannel(); defer { channel.close() }
            try channel.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
            _ = try await channel.initialize(name: "remote_switch_test")
            let result = try await channel.call("thread/list", .object(["limit": .number(1)]))
            XCTAssertEqual(result["data"].array != nil, true)
            return process.processIdentifier
        }
        let first = try await launch()
        let enrollment = Data("test-enrollment".utf8)
        try Vault.put(enrollment, key: "enrollment", paths: paths)
        try await RuntimeProcess.stop(paths: paths)
        XCTAssertEqual(runtime?.isRunning, false)
        let second = try await launch()
        XCTAssertEqual(first == second, false)
        XCTAssertEqual(try Vault.get("enrollment", paths: paths), enrollment)
        try await RuntimeProcess.stop(paths: paths)
        print("PASS: runtime restarts cleanly and preserves phone enrollment")
    }

}
