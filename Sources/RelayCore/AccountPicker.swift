import Foundation

/// A saved desktop profile exposed as one choice in the phone's account picker.
public struct RemoteAccountChoice: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let detail: String?
    public let isCurrent: Bool

    public init(id: UUID, title: String, detail: String?, isCurrent: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isCurrent = isCurrent
    }
}

/// Owns the virtual thread's UI lifecycle; Gateway only transports its messages.
@MainActor final class AccountPicker {
    static let threadID = "01a0d5dc-9c00-7000-8000-000000000043"
    private static let pinnedSectionID = "01984de2-8f74-7c91-a3b2-5c5e937cf318"
    private static let requestPrefix = "codex-profiles-picker-"
    private static let refreshLabel = "↻ Refresh limits"

    private struct Question {
        let requestID: String
        let turnID: String
        let choicesByLabel: [String: UUID]
    }

    @MainActor private final class Session {
        var template: JSON?
        var loaded = false
        var pending: Question?
        var presentation: Task<Void, Never>?
        var presentationID: UUID?
        var error: String?

        func dismiss() {
            loaded = false
            pending = nil
            presentationID = nil
            presentation?.cancel()
            presentation = nil
        }
    }

    private let choices: () -> [RemoteAccountChoice]
    private let refresh: () async -> String?
    private let select: (UUID) async -> String?
    private let emit: (JSON, StreamKey) throws -> Void
    private let diagnostic: (String) -> Void
    private let createdAt = floor(Date().timeIntervalSince1970)
    private var sessions: [StreamKey: Session] = [:]
    private var actionInProgress = false

    init(choices: @escaping () -> [RemoteAccountChoice],
         refresh: @escaping () async -> String?,
         select: @escaping (UUID) async -> String?,
         emit: @escaping (JSON, StreamKey) throws -> Void,
         diagnostic: @escaping (String) -> Void) {
        self.choices = choices
        self.refresh = refresh
        self.select = select
        self.emit = emit
        self.diagnostic = diagnostic
    }

    func close(_ key: StreamKey) {
        sessions.removeValue(forKey: key)?.dismiss()
    }

    func stop() {
        sessions.values.forEach { $0.dismiss() }
        sessions.removeAll()
        // An accepted account switch must finish even if it restarts the gateway.
    }

    private func session(for key: StreamKey) -> Session {
        if let session = sessions[key] { return session }
        let session = Session()
        sessions[key] = session
        return session
    }

    func decorateThreadList(_ response: JSON, params: JSON, key: StreamKey) -> JSON {
        guard response["error"] == .null,
              Self.shouldInjectPickerThread(in: params),
              var threads = response["result"]["data"].array else { return response }
        let session = session(for: key)
        if session.template == nil {
            session.template = threads.first { $0["id"].string != Self.threadID }
        }
        if !threads.contains(where: { $0["id"].string == Self.threadID }) {
            threads.insert(virtualThread(from: session.template), at: 0)
        }
        var result = response["result"]
        result["data"] = .array(threads)
        var decorated = response
        decorated["result"] = result
        return decorated
    }

    func handleRequest(_ request: JSON, key: StreamKey) throws -> Bool {
        guard let method = request["method"].string,
              request["params"]["threadId"].string == Self.threadID else { return false }
        let session = session(for: key)
        switch method {
        case "thread/read":
            try reply(request, result: .object(["thread": virtualThread(from: session.template)]), key: key)
            session.loaded = true
            schedulePicker(for: key)
        case "thread/resume":
            try reply(request, result: virtualThreadResume(from: session.template), key: key)
            session.loaded = true
            schedulePicker(for: key)
        case "thread/turns/list":
            try reply(request, result: .object(["data": .array([]), "nextCursor": .null, "backwardsCursor": .null]), key: key)
            session.loaded = true
            schedulePicker(for: key)
        case "thread/items/list", "thread/queue/list":
            try reply(request, result: .object(["data": .array([]), "nextCursor": .null, "backwardsCursor": .null]), key: key)
        case "thread/goal/get":
            try reply(request, result: .object(["goal": .null]), key: key)
        case "thread/loaded":
            session.loaded = true
            schedulePicker(for: key)
            try reply(request, result: .object([:]), key: key)
        case "thread/unloaded":
            session.dismiss()
            try reply(request, result: .object([:]), key: key)
        case "thread/name/set", "thread/archive", "thread/delete", "thread/settings/update", "turn/interrupt":
            try reply(request, result: .object([:]), key: key)
        case "turn/start":
            // The virtual thread never starts a model or writes conversation history.
            try reply(request, result: .object(["turn": emptyTurn()]), key: key)
        default:
            // Never forward a synthetic thread ID to the real app-server.
            if request["id"] != .null {
                try emit(.object(["id": request["id"], "error": .object([
                    "code": .number(-32601), "message": .string("This action is unavailable in the account picker.")
                ])]), key)
            }
        }
        return true
    }

    func handleResponse(_ response: JSON, key: StreamKey) -> Bool {
        guard response["method"] == .null,
              let requestID = response["id"].string,
              requestID.hasPrefix(Self.requestPrefix) else { return false }
        // Late replies from a dismissed picker belong here, never to the app-server.
        guard let session = sessions[key], session.loaded,
              let question = session.pending, question.requestID == requestID else { return true }
        session.pending = nil
        guard !actionInProgress else {
            session.error = "An account action is already in progress."
            schedulePicker(for: key)
            return true
        }
        let answer = response["result"]["answers"]["account"]["answers"].array?.first?.string
        actionInProgress = true
        Task { [self] in
            await apply(answer, question: question, session: session, key: key)
        }
        return true
    }

    private func reply(_ request: JSON, result: JSON, key: StreamKey) throws {
        guard request["id"] != .null else { return }
        try emit(.object(["id": request["id"], "result": result]), key)
    }

    private func schedulePicker(for key: StreamKey) {
        guard let session = sessions[key], session.loaded,
              session.pending == nil, session.presentation == nil else { return }
        let presentationID = UUID()
        session.presentationID = presentationID
        session.presentation = Task { [weak self, weak session] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            while !Task.isCancelled {
                guard let self, let session, self.sessions[key] === session,
                      session.loaded, session.presentationID == presentationID else { return }
                if !self.actionInProgress {
                    session.presentation = nil
                    session.presentationID = nil
                    do { try self.presentPicker(for: key, session: session) }
                    catch { self.diagnostic("Couldn't show the account picker in Remote.") }
                    return
                }
                // Cancellation owns cleanup, so an old task cannot erase its replacement.
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }

    private func presentPicker(for key: StreamKey, session: Session) throws {
        guard session.loaded, session.pending == nil else { return }
        let accounts = choices()
        let requestID = Self.requestPrefix + UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        var idsByLabel: [String: UUID] = [:]
        var usedLabels: Set<String> = [Self.refreshLabel]
        let options = accounts.map { choice in
            let title = choice.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? "Account" : title
            let base = choice.isCurrent ? "✓ \(name) · Current" : name
            var label = base
            var suffix = 2
            while usedLabels.contains(label) {
                label = "\(base) · \(suffix)"
                suffix += 1
            }
            usedLabels.insert(label)
            idsByLabel[label] = choice.id
            return JSON.object([
                "label": .string(label), "description": .string(choice.detail ?? "Limits unavailable"),
            ])
        }
        let allOptions = options + [.object([
            "label": .string(Self.refreshLabel), "description": .string("Fetch the latest limits"),
        ])]
        try emit(.object([
            "id": .string(requestID), "method": .string("item/tool/requestUserInput"),
            "params": .object([
                "threadId": .string(Self.threadID), "turnId": .string(turnID),
                "itemId": .string(UUID().uuidString.lowercased()),
                "isBlocking": .bool(true), "autoResolutionMs": .null,
                "questions": .array([.object([
                    "id": .string("account"), "header": .string(session.error == nil ? "Account" : "Try again"),
                    "question": .string(session.error ?? (accounts.isEmpty ? "No saved accounts" : "Choose an account")),
                    "isOther": .bool(false), "isSecret": .bool(false), "options": .array(allOptions),
                ])]),
            ]),
        ]), key)
        session.pending = Question(requestID: requestID, turnID: turnID, choicesByLabel: idsByLabel)
        session.error = nil
    }

    private func apply(_ answer: String?, question: Question, session: Session, key: StreamKey) async {
        // A disconnect before the action starts invalidates the submitted form.
        guard sessions[key] === session, session.loaded else {
            actionInProgress = false
            return
        }
        try? emitTurn("turn/started", status: "inProgress", id: question.turnID, key: key)
        var failure: String?
        if answer == Self.refreshLabel {
            failure = await refresh()
        } else if let answer, let id = question.choicesByLabel[answer] {
            failure = await select(id)
        } else if answer != nil {
            failure = "This choice is no longer available."
        }
        actionInProgress = false
        // Switching accounts may destroy this gateway and create a new peer with the same key.
        guard sessions[key] === session else { return }
        try? emitTurn("turn/completed", status: "completed", id: question.turnID, key: key)
        session.error = failure
        schedulePicker(for: key)
    }

    private func emitTurn(_ method: String, status: String, id: String, key: StreamKey) throws {
        try emit(.object(["method": .string(method), "params": .object([
            "threadId": .string(Self.threadID), "turn": emptyTurn(status: status, id: id),
        ])]), key)
    }

    private func emptyTurn(status: String = "completed", id: String = UUID().uuidString.lowercased()) -> JSON {
        let now = floor(Date().timeIntervalSince1970)
        return .object([
            "id": .string(id), "items": .array([]), "itemsView": .string("full"),
            "status": .string(status), "error": .null, "startedAt": .number(now),
            "completedAt": status == "completed" ? .number(now) : .null, "durationMs": .number(0),
        ])
    }

    private func virtualThread(from template: JSON? = nil) -> JSON {
        let now = floor(Date().timeIntervalSince1970)
        var thread = template?.object ?? [
            "id": .string(Self.threadID), "sessionId": .string(Self.threadID),
            "preview": .string("Choose an account"), "ephemeral": .bool(false),
            "projectId": .null, "historyMode": .string("paginated"),
            "modelProvider": .string("openai"), "model": .null, "reasoningEffort": .null,
            "createdAt": .number(now - 1), "updatedAt": .number(now),
            "recencyAt": .number(now), "status": .object(["type": .string("idle")]),
            "cwd": .string("/Codex-Profiles"), "cliVersion": .string("Relay"),
            "source": .string("appServer"), "turns": .array([]),
        ]
        thread["id"] = .string(Self.threadID)
        thread["sessionId"] = .string(Self.threadID)
        thread["forkedFromId"] = .null
        thread["parentThreadId"] = .null
        thread["preview"] = .string("Choose an account")
        thread["ephemeral"] = .bool(false)
        thread["section"] = .object(["id": .string(Self.pinnedSectionID), "name": .string("Pinned"), "appearance": .null])
        thread["sectionEnteredAt"] = .number(now)
        thread["projectId"] = .null
        thread["createdAt"] = .number(createdAt)
        thread["updatedAt"] = .number(now)
        thread["recencyAt"] = .number(now)
        thread["status"] = .object(["type": .string("idle")])
        thread["path"] = .null
        thread["cwd"] = .string("/Codex-Profiles")
        thread["cliVersion"] = .string("Relay")
        thread["originator"] = .string("Codex Profiles")
        thread["source"] = .string("appServer")
        thread["canAcceptDirectInput"] = .bool(true)
        thread["gitInfo"] = .null
        thread["name"] = .string("Profiles & Limits")
        thread["turns"] = .array([])
        return .object(thread)
    }

    private func virtualThreadStart(from template: JSON? = nil) -> JSON {
        .object([
            "thread": virtualThread(from: template), "model": .string("gpt-5"), "modelProvider": .string("openai"),
            "serviceTier": .null, "disabledPluginIds": .array([]), "cwd": .string("/Codex-Profiles"),
            "runtimeWorkspaceRoots": .array([]), "instructionSources": .array([]),
            "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"),
            "sandbox": .object(["type": .string("readOnly"), "writableRoots": .array([]),
                                "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(false), "excludeSlashTmp": .bool(false)]),
            "activePermissionProfile": .null, "reasoningEffort": .null,
            "multiAgentMode": .string("explicitRequestOnly"),
        ])
    }

    private func virtualThreadResume(from template: JSON? = nil) -> JSON {
        var result = virtualThreadStart(from: template).object ?? [:]
        result["collaborationMode"] = .null
        result["initialTurnsPage"] = .null
        result["turnsBackwardsCursor"] = .null
        result["itemsBackwardsCursor"] = .null
        return .object(result)
    }

    private static func shouldInjectPickerThread(in params: JSON) -> Bool {
        params["cursor"] == .null
            && params["archived"] != .bool(true)
            && params["projectId"] == .null && params["cwd"] == .null
            && (params["sectionId"] == .null || params["sectionId"] == .string(Self.pinnedSectionID))
            && params["searchTerm"] == .null
            && params["parentThreadId"] == .null && params["ancestorThreadId"] == .null
            && params["sortDirection"] != .string("asc")
    }
}
