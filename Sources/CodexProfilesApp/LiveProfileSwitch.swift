import Foundation
import RelayCore

/// External-auth owner for the shared desktop runtime.
/// Keep this connection alive: app-server asks its clients to renew access tokens.
@MainActor final class LiveProfileSwitch {
    private var channel: ProcessChannel?
    private(set) var profileID: UUID?
    private var accountID: String?
    private var busy = false
    var renew: ((UUID) async throws -> Data)?
    var onFailure: ((String) -> Void)?

    private func tokenParams(_ data: Data) throws -> JSON {
        let auth = try JSON(data: data)
        let profile = try AccountProfile(data: data)
        guard let access = auth["tokens"]["access_token"].string,
              let expiry = SessionMetadata(data: data).expiresAt,
              expiry > Date().addingTimeInterval(60) else {
            throw RelayError.message("Renew this profile before switching without restart.")
        }
        return .object(["type": .string("chatgptAuthTokens"),
                        "accessToken": .string(access), "chatgptAccountId": .string(profile.accountID)])
    }

    func switchAccount(to id: UUID, data: Data, previousID: UUID, previous: Data,
                       paths: RelayPaths, commit: () throws -> Void) async throws {
        guard !busy else { throw RelayError.message("A live account action is already in progress.") }
        busy = true
        defer { busy = false }
        let target = try tokenParams(data)
        let rollback = try tokenParams(previous)
        let connection = try await connect(paths)
        let current = try await connection.call("account/read", .object(["refreshToken": .bool(false)]))
        let expectedEmail = try AccountProfile(data: previous).email
        guard current["account"]["type"].string == "chatgpt",
              current["account"]["email"].string?.lowercased() == expectedEmail.lowercased() else {
            throw RelayError.message("The running account does not match the saved current profile. Use Switch with Restart to synchronize them.")
        }
        try await requireIdle(connection)
        // Once sent, a timed-out login may still have changed the runtime. Always roll back.
        do {
            try await login(target, on: connection)
            let account = try await connection.call("account/read", .object(["refreshToken": .bool(false)]))
            let expected = try AccountProfile(data: data).email
            guard account["account"]["email"].string?.lowercased() == expected.lowercased() else {
                throw RelayError.message("The runtime did not confirm the selected account.")
            }
            _ = try await connection.call("account/rateLimits/read")
            try commit()
            profileID = id
            accountID = target["chatgptAccountId"].string
        } catch {
            do {
                try await login(rollback, on: connection)
                profileID = previousID
                accountID = rollback["chatgptAccountId"].string
            } catch {
                throw RelayError.message("Live switching could not restore the previous runtime account. Use Switch with Restart to recover.")
            }
            throw RelayError.message("Live switching failed. The previous runtime account was restored. Use Switch with Restart instead.")
        }
    }

    private func login(_ params: JSON, on connection: ProcessChannel) async throws {
        let result = try await connection.call("account/login/start", params)
        guard result["type"].string == "chatgptAuthTokens" else {
            throw RelayError.message("This runtime does not support live authentication.")
        }
    }

    private func connect(_ paths: RelayPaths) async throws -> ProcessChannel {
        if let channel { return channel }
        let connection = ProcessChannel()
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            self.receive(message, on: connection)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self, self.channel === connection else { return }
            self.channel = nil
            if self.profileID != nil {
                self.onFailure?("Live authentication disconnected. Use Switch with Restart before continuing.")
            }
        }
        try connection.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
        do { _ = try await connection.initialize(name: "profiles_live_switch") }
        catch { connection.close(); throw RelayError.message("Shared runtime unavailable. Enable Remote and restart ChatGPT once.") }
        channel = connection
        return connection
    }

    private func requireIdle(_ connection: ProcessChannel) async throws {
        var cursor: JSON = .null
        var seen = Set<String>()
        repeat {
            let page = try await connection.call("thread/loaded/list", .object(["cursor": cursor, "limit": .number(100)]))
            guard let ids = page["data"].array else { throw RelayError.message("Could not check active tasks.") }
            for id in ids {
                guard let id = id.string else { throw RelayError.message("Could not check active tasks.") }
                let result = try await connection.call("thread/read", .object(["threadId": .string(id), "includeTurns": .bool(false)]))
                guard result["thread"]["status"]["type"].string == "idle" else {
                    throw RelayError.message("Finish or stop all tasks and voice sessions before switching without restart.")
                }
            }
            cursor = page["nextCursor"]
            guard cursor == .null || cursor.string != nil else { throw RelayError.message("Invalid task-list cursor.") }
            if let next = cursor.string, !seen.insert(next).inserted {
                throw RelayError.message("Could not check all active tasks.")
            }
        } while cursor != .null
    }

    func refreshCurrentCredentials() async throws {
        guard !busy, let connection = channel, let id = profileID, let renew else {
            throw RelayError.message("Live authentication is unavailable. Use Switch with Restart.")
        }
        busy = true
        defer { busy = false }
        let params = try tokenParams(try await renew(id))
        guard channel === connection, params["chatgptAccountId"].string == accountID else {
            throw RelayError.message("Account changed during renewal.")
        }
        try await login(params, on: connection)
    }

    private func receive(_ message: JSON, on connection: ProcessChannel) {
        guard message["method"].string == "account/chatgptAuthTokens/refresh", message["id"] != .null else { return }
        Task { [weak self, weak connection] in
            guard let self, let connection, self.channel === connection else { return }
            do {
                let previous = message["params"]["previousAccountId"].string
                guard !busy, let id = profileID, previous == nil || previous == accountID, let renew else {
                    throw RelayError.message("Account is changing.")
                }
                busy = true
                defer { busy = false }
                let params = try tokenParams(try await renew(id))
                guard self.channel === connection, params["chatgptAccountId"].string == accountID else {
                    throw RelayError.message("Account changed during renewal.")
                }
                try connection.send(.object(["id": message["id"], "result": .object([
                    "accessToken": params["accessToken"], "chatgptAccountId": params["chatgptAccountId"], "chatgptPlanType": .null
                ])]))
            } catch {
                let text = "Live token renewal failed. Use Switch with Restart or sign in again."
                try? connection.send(.object(["id": message["id"], "error": .object(["code": .number(-32603), "message": .string(text)])]))
                onFailure?(text)
            }
        }
    }

    func close() {
        profileID = nil
        accountID = nil
        let previous = channel
        channel = nil
        previous?.close()
    }
}
