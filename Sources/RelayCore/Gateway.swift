import Foundation
import os

@MainActor public final class Gateway {
    public enum State: Equatable { case stopped, connecting, online, retrying(Int), failed(String) }
    public var onState: ((State) -> Void)?
    public var onPeerCount: ((Int) -> Void)?
    public var onMethod: ((String) -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    public var profileOptions: (() -> [RemoteProfileOption])?
    public var onProfileSwitch: ((UUID) async -> String?)?
    /// A LAN URL served by the macOS app. When present, the virtual chat
    /// renders profile choices as tappable Markdown links.
    public var profileControlURL: (() -> String?)?
    private let api: RemoteAPI
    private let paths: RelayPaths
    private let logger = Logger(subsystem: "io.github.qwersyk.codexprofiles", category: "RemoteGateway")
    public static let virtualControlEnabled = true
    public static let virtualProjectEnabled = true
    private var controlThreadTemplate: JSON?
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private let session: URLSession
    private var peers: [StreamKey: ProcessChannel] = [:]
    private var pendingRequests: [StreamKey: [String: JSON]] = [:]
    private var activity: [StreamKey: Date] = [:]
    private var legacy: [String: String] = [:]
    private var sequences: [StreamKey: Int] = [:]
    private var delivered: [StreamKey: Int] = [:]
    private var assembler = ChunkAssembler()
    private(set) var outbox = Outbox()
    private var cursor: String?
    private var writer: Task<Void, Never>?
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var generation = UUID()
    private let controlProjectID = "01a0d5dc-9c00-7000-8000-000000000042"
    private let controlThreadID = "01a0d5dc-9c00-7000-8000-000000000043"
    private let controlRoot = "/Codex Profiles"
    public init(api: RemoteAPI, paths: RelayPaths) {
        self.api = api; self.paths = paths
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config)
    }
    public func start() {
        guard runTask == nil else { return }
        logger.notice("Remote gateway starting")
        runTask = Task { [weak self] in await self?.run() }
    }
    public func stop() {
        runTask?.cancel(); runTask = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil
        writer?.cancel(); writer = nil; queue.removeAll(); queuedBytes = 0; generation = UUID()
        let old = peers; peers.removeAll(); for (_, p) in old { p.onClose = nil; p.close() }
        activity.removeAll(); delivered.removeAll(); sequences.removeAll(); legacy.removeAll(); pendingRequests.removeAll(); assembler = ChunkAssembler(); outbox = Outbox(); cursor = nil; controlThreadTemplate = nil
        onPeerCount?(0); onState?(.stopped)
    }
    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            onState?(.connecting)
            do {
                let e = try await api.ensureEnrollment(forceRefresh: attempt > 0)
                try Task.checkCancellation()
                let ws = session.webSocketTask(with: api.socketRequest(e, cursor: cursor))
                ws.maximumMessageSize = 160 * 1024; socket = ws; generation = UUID(); ws.resume()
                try await ping(ws)
                try Task.checkCancellation(); attempt = 0; logger.notice("Remote gateway socket online"); onState?(.online)
                queue = outbox.frames.map(\.data); queuedBytes = outbox.bytes; pump()
                let heartbeat = Task { [weak self, weak ws] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: 10_000_000_000)
                            guard let self, let ws else { return }
                            try await self.ping(ws)
                            self.expirePeers()
                            if e.expires < Date().addingTimeInterval(180) { ws.cancel(with: .goingAway, reason: nil); return }
                        } catch { ws?.cancel(with: .goingAway, reason: nil); return }
                    }
                }
                defer { heartbeat.cancel() }
                while !Task.isCancelled {
                    let packet = try await ws.receive()
                    let data: Data
                    switch packet { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                    guard data.count <= 160 * 1024 else { throw RelayError.message("Unsupported Remote packet.") }
                    try await receive(JSON(data: data))
                }
            } catch {
                if Task.isCancelled { return }
                let failure = error as NSError
                let http = (socket?.response as? HTTPURLResponse)?.statusCode
                onDiagnostic?("Transport: \(failure.domain) \(failure.code), HTTP \(http.map(String.init) ?? "—")")
                writer?.cancel(); writer = nil; queue.removeAll(); queuedBytes = 0
                socket?.cancel(with: .goingAway, reason: nil); socket = nil; generation = UUID()
                if let apiError = error as? RemoteAPIError, [401, 403, 404].contains(apiError.status) {
                    onState?(.failed(apiError.localizedDescription)); runTask = nil; return
                }
                attempt += 1
                let requested = (error as? RemoteAPIError)?.retryAfter ?? 0
                let delay = max(requested, min(30, pow(2, Double(min(attempt, 5))))) + Double.random(in: 0...1)
                onState?(.retrying(Int(delay)))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) } catch { return }
            }
        }
    }
    private func ping(_ ws: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let gate = PingCompletion(c)
            ws.sendPing { error in gate.finish(error) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { gate.finish(URLError(.timedOut)) }
        }
    }
    func receive(_ envelope: JSON) async throws {
        guard let client = envelope["client_id"].string, !client.isEmpty, client.count < 256, let type = envelope["type"].string else { throw RelayError.message("Unsupported Remote version.") }
        let message = envelope["message"]
        let methodLabel = message["method"].string ?? "notification"
        logger.notice("Remote envelope: \(type, privacy: .public), method: \(methodLabel, privacy: .public)")
        let isInit = message["method"].string == "initialize"
        let stream: String
        if let explicit = envelope["stream_id"].string { stream = explicit }
        else if let saved = legacy[client] { stream = saved }
        else { stream = UUID().uuidString; if isInit { legacy[client] = stream } }
        guard !stream.isEmpty, stream.count < 256 else { return }
        let key = StreamKey(client: client, stream: stream)
        switch type {
        case "ack":
            if let seq = envelope["seq_id"].int { outbox.acknowledge(key: key, sequence: seq, segment: envelope["segment_id"].int) }
        case "ping":
            if peers[key] != nil { activity[key] = Date() }
            try enqueueEvent(.object(["type": .string("pong"), "status": .string(peers[key] == nil ? "unknown" : "active")]), key: key)
        case "client_closed": closePeer(key)
        case "client_message", "client_message_chunk":
            let seq = envelope["seq_id"].int
            if let seq, let last = delivered[key], seq <= last { break }
            let complete: JSON
            if type == "client_message_chunk" { guard let m = try assembler.accept(envelope, key: key) else { return }; complete = m }
            else { complete = message }
            do { try await forward(complete, key: key) }
            catch {
                closePeer(key)
                onDiagnostic?("Open ChatGPT through Relay on this Mac.")
                if complete["id"] != .null {
                    try emit(.object(["id": complete["id"], "error": .object([
                        "code": .number(-32000), "message": .string("Start ChatGPT through Relay on your Mac, then reconnect this host.")
                    ])]), key: key)
                }
            }
            if let seq { delivered[key] = seq }
        default: throw RelayError.message("Unknown Remote message type.")
        }
        if let next = envelope["cursor"].string { cursor = next }
    }
    private func forward(_ message: JSON, key: StreamKey) async throws {
        if let method = message["method"].string {
            onMethod?(method)
            logger.info("Phone RPC method: \(method, privacy: .public)")
            if !WireProtocol.permits(method) {
                if message["id"] != .null { try emit(.object(["id": message["id"], "error": .object(["code": .number(-32601), "message": .string("This operation is available only on the Mac.")])]), key: key) }; return
            }
            if method == "initialize" {
                closePeer(key)
                guard peers.count < 8 else { throw RelayError.message("Connection limit reached.") }
                // Query the work account's policy without enabling its native Remote transport.
                let check = ProcessChannel()
                try check.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
                defer { check.close() }
                _ = try await check.initialize(name: "relay_policy_check")
                _ = try await check.call("remoteControl/status/read")
                let peer = ProcessChannel()
                try peer.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
                peers[key] = peer
                peer.onMessage = { [weak self, weak peer] response in
                    guard let self, self.peers[key] === peer else { return }
                    do { try self.forwardResponse(response, key: key) } catch { self.closePeer(key); self.onState?(.failed("Remote buffer is full. Reopen the task on your phone.")) }
                }
                peer.onClose = { [weak self, weak peer] in
                    guard let self, self.peers[key] === peer else { return }; self.closePeer(key)
                }
                onPeerCount?(peers.count)
            }
        }
        guard let peer = peers[key] else {
            if message["id"] != .null {
                try emit(.object(["id": message["id"], "error": .object([
                    "code": .number(-32000),
                    "message": .string("The local session disconnected. Reopen this host in Remote; pairing is still saved.")
                ])]), key: key)
            }
            return
        }
        activity[key] = Date()
        if Self.virtualControlEnabled {
            if try handleVirtualControlRequest(message, key: key) { return }
        }
        if let id = Self.rpcKey(message["id"]) { pendingRequests[key, default: [:]][id] = message }
        var forwarded = message
        if Self.virtualControlEnabled, Self.shouldInjectControlThread(into: message) {
            let requestedLimit = message["params"]["limit"].int ?? 25
            forwarded["params"]["limit"] = .number(Double(requestedLimit - 1))
        }
        try peer.send(forwarded)
    }

    private func forwardResponse(_ response: JSON, key: StreamKey) throws {
        guard let id = Self.rpcKey(response["id"]),
              let request = pendingRequests[key]?.removeValue(forKey: id) else { try emit(response, key: key); return }
        let method = request["method"].string ?? "unknown"
        if response["error"] != .null {
            let rawCode = response["error"]["code"]
            let code: String
            if let value = rawCode.string { code = value }
            else if case .number(let value) = rawCode { code = String(value) }
            else { code = "unknown" }
            logger.error("Local RPC failed: \(method, privacy: .public), code \(code, privacy: .public)")
            try emit(response, key: key); return
        }
        logger.notice("Local app-server replied to: \(method, privacy: .public)")
        if !Self.virtualControlEnabled {
            if method == "thread/list" || method == "project/list" {
                let rowCount = response["result"]["data"].array?.count ?? -1
                logger.notice("Forwarding unmodified \(method, privacy: .public): \(rowCount) rows")
            }
            try emit(response, key: key)
            return
        }
        var updated = response
        switch request["method"].string {
        case "project/list":
            guard Self.virtualProjectEnabled else { break }
            var projects = updated["result"]["data"].array ?? []
            projects.removeAll { $0["id"].string == controlProjectID }
            projects.insert(virtualProject(), at: 0)
            updated["result"]["data"] = .array(projects)
            logger.info("Injected virtual project into project/list")
        case "thread/list":
            guard Self.shouldInjectControlThread(into: request) else {
                try emit(updated, key: key); return
            }
            var threads = updated["result"]["data"].array ?? []
            threads.removeAll { $0["id"].string == controlThreadID }
            if let template = threads.first { controlThreadTemplate = template }
            var controlChat = virtualThread(includeGreeting: false)
            if !Self.virtualProjectEnabled { controlChat["projectId"] = .null }
            threads.insert(controlChat, at: 0)
            updated["result"]["data"] = .array(threads)
            let byteCount = try updated.data().count
            logger.info("Injected virtual chat into thread/list: \(threads.count) rows, \(byteCount) bytes")
        default: break
        }
        try emit(updated, key: key)
    }

    private func handleVirtualControlRequest(_ request: JSON, key: StreamKey) throws -> Bool {
        guard let method = request["method"].string else { return false }
        let params = request["params"]
        let threadID = params["threadId"].string
        let projectID = params["projectId"].string
        if method == "project/read", projectID == controlProjectID {
            logger.debug("Served virtual project/read")
            try reply(request, result: .object(["project": virtualProject()]), key: key); return true
        }
        if method == "thread/list" {
            if projectID == controlProjectID || Self.includesVirtualRoot(params["cwd"], root: controlRoot) {
                let archived = params["archived"] == .bool(true)
                let threadRows: [JSON] = archived ? [] : [virtualThread(includeGreeting: false)]
                logger.debug("Served virtual thread/list")
                try reply(request, result: .object([
                    "data": .array(threadRows), "nextCursor": .null, "backwardsCursor": .null,
                ]), key: key); return true
            }
        }
        if method == "thread/start", projectID == controlProjectID || params["cwd"].string == controlRoot {
            logger.debug("Served virtual thread/start")
            try reply(request, result: virtualThreadStart(), key: key); return true
        }
        if threadID == controlThreadID {
            switch method {
            case "thread/read":
                logger.info("Served virtual thread/read")
                try reply(request, result: .object(["thread": virtualThread(includeGreeting: true)]), key: key)
                return true
            case "thread/resume":
                logger.info("Served virtual thread/resume")
                try reply(request, result: virtualThreadResume(), key: key); return true
            case "thread/turns/list":
                logger.debug("Served virtual thread/turns/list")
                try reply(request, result: .object([
                    "data": .array([greetingTurn()]), "nextCursor": .null, "backwardsCursor": .null,
                ]), key: key); return true
            case "thread/items/list":
                logger.debug("Served virtual thread/items/list")
                let turn = greetingTurn()
                let item = turn["items"].array?.first ?? .null
                try reply(request, result: .object([
                    "data": .array([.object(["turnId": turn["id"], "item": item])]),
                    "nextCursor": .null, "backwardsCursor": .null,
                ]), key: key); return true
            case "thread/queue/list":
                try reply(request, result: .object(["data": .array([]), "nextCursor": .null]), key: key)
                return true
            case "thread/goal/get":
                try reply(request, result: .object(["goal": .null]), key: key)
                return true
            case "thread/name/set", "thread/archive", "thread/delete", "thread/settings/update", "turn/interrupt":
                try reply(request, result: .object([:]), key: key); return true
            case "thread/loaded", "thread/unloaded":
                return true
            case "turn/start":
                logger.info("Handling virtual turn/start")
                _ = try handleProfileCommand(request, key: key)
                return true
            default: break
            }
        }
        return false
    }

    private func reply(_ request: JSON, result: JSON, key: StreamKey) throws {
        if request["id"] != .null { try emit(.object(["id": request["id"], "result": result]), key: key) }
    }

    private static func rpcKey(_ id: JSON) -> String? {
        if let value = id.string { return "s:\(value)" }
        if case .number(let value) = id, value.isFinite { return "n:\(value)" }
        return nil
    }

    private static func includesVirtualRoot(_ value: JSON, root: String) -> Bool {
        if value.string == root { return true }
        return value.array?.contains { $0.string == root } ?? false
    }

    private static func shouldInjectControlThread(into request: JSON) -> Bool {
        guard request["method"].string == "thread/list" else { return false }
        let params = request["params"]
        let limit = params["limit"].int ?? 25
        return limit > 1 && params["cursor"] == .null && params["archived"] != .bool(true)
            && params["projectId"] == .null && params["cwd"] == .null
            && params["sectionId"] == .null && params["searchTerm"] == .null
            && params["parentThreadId"] == .null && params["ancestorThreadId"] == .null
            && params["sortDirection"] != .string("asc")
    }

    private func virtualProject() -> JSON {
        let now = floor(Date().timeIntervalSince1970)
        return .object([
            "id": .string(controlProjectID), "name": .string("Profiles & Limits"),
            "roots": .array([.object(["path": .string(controlRoot)])]),
            "metadata": .object(["kind": .string("relayVirtualControl")]),
            "position": .number(0), "createdAt": .number(now - 1),
            "updatedAt": .number(now), "recencyAt": .number(now),
        ])
    }

    private func virtualThread(includeGreeting: Bool) -> JSON {
        let now = floor(Date().timeIntervalSince1970)
        if var thread = controlThreadTemplate {
            thread["id"] = .string(controlThreadID)
            thread["sessionId"] = .string(controlThreadID)
            thread["forkedFromId"] = .null
            thread["parentThreadId"] = .null
            thread["preview"] = .string("Codex account controls. Send /accounts to view profiles and limits.")
            thread["ephemeral"] = .bool(false)
            thread["section"] = .null
            thread["sectionEnteredAt"] = .null
            thread["projectId"] = Self.virtualProjectEnabled ? .string(controlProjectID) : .null
            thread["cwd"] = .string(controlRoot)
            thread["createdAt"] = .number(now - 1)
            thread["updatedAt"] = .number(now)
            thread["recencyAt"] = .number(now)
            thread["status"] = .object(["type": .string(includeGreeting ? "idle" : "notLoaded")])
            thread["path"] = .null
            thread["environments"] = .null
            thread["extra"] = .null
            thread["canAcceptDirectInput"] = includeGreeting ? .bool(true) : .null
            thread["gitInfo"] = .null
            thread["name"] = .string("Profiles & Limits")
            thread["turns"] = .array(includeGreeting ? [greetingTurn()] : [])
            return thread
        }
        return .object([
            "id": .string(controlThreadID), "environments": .null, "extra": .null,
            "sessionId": .string(controlThreadID), "forkedFromId": .null, "parentThreadId": .null,
            "preview": .string("Codex account controls. Send /accounts to view profiles and limits."),
            // Every operation for this fixed ID is intercepted above. No local
            // app-server thread is created or persisted for the control chat.
            "ephemeral": .bool(false), "section": .null, "sectionEnteredAt": .null,
            "projectId": Self.virtualProjectEnabled ? .string(controlProjectID) : .null, "historyMode": .string("paginated"),
            "modelProvider": .string("openai"), "model": .null, "reasoningEffort": .null,
            "createdAt": .number(now - 1), "updatedAt": .number(now), "recencyAt": .number(now),
            "status": .object(["type": .string(includeGreeting ? "idle" : "notLoaded")]), "path": .null,
            "cwd": .string(controlRoot), "cliVersion": .string("Relay"),
            "originator": .string("Relay"), "source": .string("appServer"),
            "canAcceptDirectInput": .bool(true), "threadSource": .string("appServer"),
            "agentNickname": .null, "agentRole": .null, "gitInfo": .null,
            "name": .string("Profiles & Limits"), "daybreakEnabled": .null,
            "turns": .array(includeGreeting ? [greetingTurn()] : []),
        ])
    }

    private func greetingTurn() -> JSON {
        let now = floor(Date().timeIntervalSince1970)
        let item = JSON.object([
            "id": .string("01a0d5dc-9c00-7000-8000-000000000044"), "type": .string("agentMessage"),
            "text": .string(Self.accountList(profileOptions?() ?? [], controlURL: profileControlURL?())), "phase": .string("final_answer"),
            "memoryCitation": .null, "delivery": .null, "questions": .null,
        ])
        return .object([
            "id": .string("01a0d5dc-9c00-7000-8000-000000000045"), "items": .array([item]),
            "itemsView": .string("full"), "status": .string("completed"), "error": .null,
            "startedAt": .number(now), "completedAt": .number(now), "durationMs": .number(0),
        ])
    }

    private func virtualThreadStart() -> JSON {
        let cwd = controlRoot
        return .object([
            "thread": virtualThread(includeGreeting: true), "model": .string("gpt-5"),
            "modelProvider": .string("openai"), "serviceTier": .null, "disabledPluginIds": .array([]),
            "cwd": .string(cwd), "runtimeWorkspaceRoots": .array([.string(cwd)]),
            "instructionSources": .array([]), "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"), "sandbox": .object([
                "type": .string("workspaceWrite"), "writableRoots": .array([.string(cwd)]),
                "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(false), "excludeSlashTmp": .bool(false),
            ]),
            "activePermissionProfile": .null, "reasoningEffort": .null,
            "multiAgentMode": .string("explicitRequestOnly"),
        ])
    }

    private func virtualThreadResume() -> JSON {
        var result = virtualThreadStart().object ?? [:]
        result["collaborationMode"] = .null
        result["initialTurnsPage"] = .null
        result["turnsBackwardsCursor"] = .null
        result["itemsBackwardsCursor"] = .null
        return .object(result)
    }

    private func handleProfileCommand(_ request: JSON, key: StreamKey) throws -> Bool {
        let input = request["params"]["input"].array ?? []
        let text = input.compactMap { item -> String? in
            guard item["type"].string == "text" else { return nil }
            return item["text"].string
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace)
        let first = words.first?.lowercased()
        let options = profileOptions?() ?? []
        let replacement: String
        var switchTarget: UUID?
        if first == "/accounts" || first == "/profiles" {
            replacement = Self.accountList(options, controlURL: profileControlURL?())
        } else if first == "/use", words.count == 2, let index = Int(words[1]), options.indices.contains(index - 1) {
            let target = options[index - 1]
            if target.isCurrent {
                replacement = "**\(Self.markdownSafe(target.name))** is already the active Codex profile.\n\nSend `/accounts` to see profile limits."
            } else {
                switchTarget = target.id
                replacement = "Switching Codex to **\(Self.markdownSafe(target.name))**. The Mac app will restart; send `/accounts` after reconnecting to confirm the active profile."
            }
        } else {
            replacement = "Use `/accounts` to view the saved profiles, then send `/use` followed by a number, for example `/use 2`."
        }
        try emitSyntheticTurn(request, text: replacement, key: key)
        if let switchTarget {
            Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                let failure = await self.onProfileSwitch?(switchTarget)
                if let failure {
                    try? self.emitSyntheticTurn(request, text: "Profile switch failed: \(failure)", key: key, acknowledgeRequest: false)
                }
            }
        }
        return true
    }

    private func emitSyntheticTurn(_ request: JSON, text: String, key: StreamKey, acknowledgeRequest: Bool = true) throws {
        let threadID = request["params"]["threadId"].string ?? ""
        let turnID = UUID().uuidString.lowercased()
        let itemID = UUID().uuidString.lowercased()
        let now = floor(Date().timeIntervalSince1970)
        let startedAt = JSON.object([
            "id": .string(turnID), "items": .array([]), "itemsView": .string("full"), "status": .string("inProgress"),
            "error": .null, "startedAt": .number(now), "completedAt": .null, "durationMs": .null,
        ])
        if acknowledgeRequest && request["id"] != .null {
            try emit(.object([
                "id": request["id"],
                "result": .object(["turn": startedAt]),
            ]), key: key)
        }
        try emit(.object(["method": .string("turn/started"), "params": .object([
            "threadId": .string(threadID), "turn": startedAt,
        ])]), key: key)
        let item = JSON.object([
            "id": .string(itemID), "type": .string("agentMessage"), "text": .string(text),
            "phase": .string("final_answer"), "memoryCitation": .null, "delivery": .null, "questions": .null,
        ])
        var startedItem = item
        startedItem["text"] = .string("")
        try emit(.object(["method": .string("item/started"), "params": .object([
            "threadId": .string(threadID), "turnId": .string(turnID), "item": startedItem, "startedAtMs": .number(now * 1000),
        ])]), key: key)
        try emit(.object(["method": .string("item/agentMessage/delta"), "params": .object([
            "threadId": .string(threadID), "turnId": .string(turnID), "itemId": .string(itemID), "delta": .string(text),
        ])]), key: key)
        try emit(.object(["method": .string("item/completed"), "params": .object([
            "threadId": .string(threadID), "turnId": .string(turnID), "item": item, "completedAtMs": .number(now * 1000),
        ])]), key: key)
        let completed = JSON.object([
            "id": .string(turnID), "items": .array([item]), "itemsView": .string("full"), "status": .string("completed"),
            "error": .null, "startedAt": .number(now), "completedAt": .number(now), "durationMs": .number(0),
        ])
        try emit(.object(["method": .string("turn/completed"), "params": .object([
            "threadId": .string(threadID), "turn": completed,
        ])]), key: key)
    }

    private static func accountList(_ options: [RemoteProfileOption], controlURL: String?) -> String {
        guard !options.isEmpty else { return "No saved Codex profiles were found. Add and save a profile in Codex Profiles on the Mac." }
        let rows = options.enumerated().map { index, profile in
            let active = profile.isCurrent ? " · **ACTIVE**" : ""
            let email = profile.email.map { " — \(markdownSafe($0))" } ?? ""
            let details = profile.details.map { "\n   \($0)" } ?? "\n   Limits not loaded yet."
            let action: String
            if let controlURL {
                let url = controlURL.replacingOccurrences(of: "%d", with: String(index + 1))
                action = "\n   [\(profile.isCurrent ? "🟢 Active" : "🔵 Use this profile")](\(url))"
            } else {
                action = ""
            }
            return "\(index + 1). **\(markdownSafe(profile.name))**\(email)\(active)\(details)\(action)"
        }
        let hint = controlURL == nil
            ? "Send `/use N` to switch profiles (for example, `/use 2`)."
            : "Tap a profile link to switch it on the Mac, or send `/use N` as a fallback."
        return "## Codex Profiles\n\n" + rows.joined(separator: "\n\n") + "\n\n\(hint) Limits are the latest readings saved on this Mac."
    }

    private static func markdownSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "`", with: "\\`")
    }
    private func emit(_ message: JSON, key: StreamKey) throws {
        let seq = sequences[key, default: 1]; sequences[key] = seq + 1
        let frames = try WireProtocol.frames(message: message, key: key, sequence: seq)
        try outbox.append(frames)
        if socket != nil { for f in frames { try enqueue(f.data) } }
    }
    private func enqueueEvent(_ event: JSON, key: StreamKey) throws {
        var event = event
        let seq = sequences[key, default: 1]; sequences[key] = seq + 1
        event["client_id"] = .string(key.client); event["stream_id"] = .string(key.stream); event["seq_id"] = .number(Double(seq))
        let frame = OutboundFrame(key: key, sequence: seq, segment: nil, data: try event.data())
        try outbox.append([frame]); if socket != nil { try enqueue(frame.data) }
    }
    private func enqueue(_ data: Data) throws {
        guard queuedBytes + data.count < 48 * 1024 * 1024 else { throw RelayError.message("Remote queue is full.") }
        queue.append(data); queuedBytes += data.count; pump()
    }
    private func pump() {
        guard writer == nil, let socket, !queue.isEmpty else { return }
        let current = generation
        writer = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            defer { if self.generation == current { self.writer = nil } }
            while !Task.isCancelled, self.generation == current, !self.queue.isEmpty {
                let data = self.queue.removeFirst(); self.queuedBytes -= data.count
                do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
                catch { socket.cancel(with: .goingAway, reason: nil); return }
            }
        }
    }
    private func closePeer(_ key: StreamKey) {
        let p = peers.removeValue(forKey: key); p?.onClose = nil; p?.close()
        pendingRequests.removeValue(forKey: key)
        activity.removeValue(forKey: key); assembler.remove(key); delivered.removeValue(forKey: key)
        // Keep monotonically increasing sequence ids within a stream, including re-initialize.
        outbox.remove(key); onPeerCount?(peers.count)
    }
    private func expirePeers() {
        for (key, time) in activity where Date().timeIntervalSince(time) > 300 { closePeer(key) }
    }
}

private final class PingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
    func finish(_ error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}
