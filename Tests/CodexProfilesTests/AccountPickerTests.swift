import Foundation
@testable import RelayCore

@MainActor enum AccountPickerTests {
    @MainActor private final class Harness {
        let key = StreamKey(client: "picker-test", stream: "one")
        var messages: [(StreamKey, JSON)] = []
        var accounts: [RemoteAccountChoice] = []
        var selections: [UUID] = []
        var refreshes = 0
        var refreshContinuation: CheckedContinuation<String?, Never>?
        var holdRefresh = false
        lazy var picker = AccountPicker(
            choices: { [unowned self] in accounts },
            refresh: { [unowned self] in
                refreshes += 1
                if holdRefresh {
                    return await withCheckedContinuation { refreshContinuation = $0 }
                }
                return nil
            },
            select: { [unowned self] id in selections.append(id); return nil },
            emit: { [unowned self] message, key in messages.append((key, message)) },
            diagnostic: { message in preconditionFailure(message) }
        )
        var prompts: [JSON] {
            messages.map(\.1).filter { $0["method"].string == "item/tool/requestUserInput" }
        }
        func request(_ method: String, key: StreamKey? = nil) throws {
            let handled = try picker.handleRequest(.object([
                "id": .string(UUID().uuidString), "method": .string(method),
                "params": .object(["threadId": .string(AccountPicker.threadID)]),
            ]), key: key ?? self.key)
            XCTAssertEqual(handled, true)
        }
        func answer(_ prompt: JSON, _ label: String, key: StreamKey? = nil) {
            XCTAssertEqual(picker.handleResponse(.object([
                "id": prompt["id"], "result": .object([
                    "answers": .object(["account": .object(["answers": .array([.string(label)])])]),
                ]),
            ]), key: key ?? self.key), true)
        }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Account picker timed out")
    }

    static func run() async throws {
        try listsStayIntact()
        try await reopenAndLateResponses()
        try await serializeActionsAndPreserveErrors()
        try await concurrentClientsDoNotOverlapActions()
        try await closedStreamDoesNotReceiveCompletion()
        try await labelsSelectTheRightAccount()
        print("PASS: account picker lifecycle, action isolation, labels and list preservation")
    }

    private static func listsStayIntact() throws {
        let h = Harness(); defer { h.picker.stop() }
        let originalThread: JSON = .object(["id": .string("real-thread"), "name": .string("Real task")])
        let original: JSON = .object(["id": .number(1), "result": .object([
            "data": .array([originalThread]), "nextCursor": .string("page-two"), "other": .bool(true),
        ])])
        let decorated = h.picker.decorateThreadList(original, params: .object([:]), key: h.key)
        XCTAssertEqual(decorated["result"]["data"].array?.count, 2)
        XCTAssertEqual(decorated["result"]["data"].array?.last, originalThread)
        XCTAssertEqual(decorated["result"]["nextCursor"], .string("page-two"))
        XCTAssertEqual(decorated["result"]["other"], .bool(true))
        XCTAssertEqual(h.picker.decorateThreadList(decorated, params: .object([:]), key: h.key), decorated)
        for params: JSON in [
            .object(["cursor": .string("page-two")]), .object(["archived": .bool(true)]),
            .object(["cwd": .string("/project")]), .object(["projectId": .string("project")]),
            .object(["searchTerm": .string("task")]), .object(["sectionId": .string("custom")]),
        ] {
            XCTAssertEqual(h.picker.decorateThreadList(original, params: params, key: h.key), original)
        }
        let malformed: JSON = .object(["id": .number(1), "result": .object(["data": .null])])
        XCTAssertEqual(h.picker.decorateThreadList(malformed, params: .object([:]), key: h.key), malformed)
        let realRequest: JSON = .object([
            "method": .string("thread/read"), "params": .object(["threadId": .string("real-thread")]),
        ])
        XCTAssertEqual(try h.picker.handleRequest(realRequest, key: h.key), false)
        try h.request("thread/unsupported")
        XCTAssertEqual(h.messages.last?.1["error"]["code"], .number(-32601))
    }

    private static func reopenAndLateResponses() async throws {
        let h = Harness(); defer { h.picker.stop() }
        try h.request("thread/read")
        // Cancel a scheduled presentation and immediately replace it on the same stream.
        try h.request("thread/unloaded")
        try h.request("thread/resume")
        try await waitUntil { h.prompts.count == 1 }
        let first = h.prompts[0]
        try h.request("thread/read")
        try h.request("thread/turns/list")
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(h.prompts.count, 1)
        try h.request("thread/unloaded")
        try h.request("thread/loaded")
        try await waitUntil { h.prompts.count == 2 }
        XCTAssertEqual(h.prompts[1]["id"] == first["id"], false)
        h.answer(first, "↻ Refresh limits")
        XCTAssertEqual(h.refreshes, 0)
        XCTAssertEqual(h.prompts.count, 2)
    }

    private static func serializeActionsAndPreserveErrors() async throws {
        let h = Harness(); defer { h.picker.stop() }
        h.holdRefresh = true
        try h.request("thread/read")
        try await waitUntil { h.prompts.count == 1 }
        let prompt = h.prompts[0]
        h.answer(prompt, "↻ Refresh limits")
        h.answer(prompt, "↻ Refresh limits")
        try await waitUntil { h.refreshContinuation != nil }
        try h.request("thread/read")
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(h.prompts.count, 1)
        XCTAssertEqual(h.refreshes, 1)
        h.refreshContinuation?.resume(returning: "Refresh failed. Try again.")
        h.refreshContinuation = nil
        try await waitUntil { h.prompts.count == 2 }
        XCTAssertEqual(h.prompts[1]["params"]["questions"].array?.first?["question"], .string("Refresh failed. Try again."))
        let textEvents = h.messages.filter { $0.1["method"].string?.contains("agentMessage") == true }
        XCTAssertEqual(textEvents.count, 0)
    }

    private static func closedStreamDoesNotReceiveCompletion() async throws {
        let h = Harness(); defer { h.picker.stop() }
        h.holdRefresh = true
        try h.request("thread/read")
        try await waitUntil { h.prompts.count == 1 }
        h.answer(h.prompts[0], "↻ Refresh limits")
        try await waitUntil { h.refreshContinuation != nil }
        h.picker.close(h.key)
        try h.request("thread/read")
        h.refreshContinuation?.resume(returning: "Old failure")
        h.refreshContinuation = nil
        try await waitUntil { h.prompts.count == 2 }
        XCTAssertEqual(h.messages.filter { $0.1["method"].string == "turn/completed" }.count, 0)
        XCTAssertEqual(h.prompts[1]["params"]["questions"].array?.first?["question"], .string("No saved accounts"))
    }

    private static func concurrentClientsDoNotOverlapActions() async throws {
        let h = Harness(); defer { h.picker.stop() }
        let other = StreamKey(client: "another-phone", stream: "two")
        h.holdRefresh = true
        try h.request("thread/read")
        try h.request("thread/read", key: other)
        try await waitUntil { h.prompts.count == 2 }
        let first = h.messages.first { $0.0 == h.key && $0.1["method"].string == "item/tool/requestUserInput" }!.1
        let second = h.messages.first { $0.0 == other && $0.1["method"].string == "item/tool/requestUserInput" }!.1
        h.answer(first, "↻ Refresh limits")
        try await waitUntil { h.refreshContinuation != nil }
        h.answer(second, "↻ Refresh limits", key: other)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(h.refreshes, 1)
        XCTAssertEqual(h.prompts.count, 2)
        // Closing the first view must not reopen it when its refresh completes.
        try h.request("thread/unloaded")
        h.refreshContinuation?.resume(returning: nil)
        h.refreshContinuation = nil
        try await waitUntil { h.prompts.count == 3 }
        XCTAssertEqual(h.messages.last?.0, other)
        XCTAssertEqual(h.refreshes, 1)
    }

    private static func labelsSelectTheRightAccount() async throws {
        let h = Harness(); defer { h.picker.stop() }
        h.accounts = ["↻ Refresh limits", "Same", "Same", "Same · 2"].map {
            RemoteAccountChoice(id: UUID(), title: $0, detail: "5h: 50% left", isCurrent: false)
        }
        try h.request("thread/read")
        try await waitUntil { h.prompts.count == 1 }
        let prompt = h.prompts[0]
        let labels = prompt["params"]["questions"].array!.first!["options"].array!.compactMap { $0["label"].string }
        XCTAssertEqual(Set(labels).count, h.accounts.count + 1)
        XCTAssertEqual(labels.last, "↻ Refresh limits")
        h.answer(prompt, labels[0])
        try await waitUntil { h.selections.count == 1 }
        XCTAssertEqual(h.selections[0], h.accounts[0].id)
        XCTAssertEqual(h.refreshes, 0)
        try await waitUntil { h.prompts.count == 2 }
    }
}
