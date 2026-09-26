import AppKit
import SwiftUI
import RelayCore

@MainActor final class RemoteModel: ObservableObject {
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var connected = false
    @Published private(set) var runtimeReady = false
    @Published private(set) var desktopAttached = false
    private var attachedPID: pid_t?
    private var desktopGeneration = UUID()
    @Published private(set) var enabled = false
    @Published private(set) var status = "Disconnected"
    @Published var pairing: Pairing?
    @Published var pairingError: String?
    @Published var pairingBusy = false
    @Published var error: String?
    let paths = RelayPaths()
    private var identity: PhoneIdentity?
    private var api: RemoteAPI?
    private var gateway: Gateway?
    private var monitor: ProcessChannel?
    private var monitorTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var pairingWindow: RemotePairingWindow?
    @Published private(set) var changingDesktop = false
    var credentials: ((UUID) async throws -> Data)?
    var savedCredentials: ((UUID) throws -> Data)?
    var accountChoices: (() -> [RemoteAccountChoice])?
    var refreshAccountLimits: (() async -> String?)?
    var selectDesktopAccount: ((UUID) async -> String?)?

    var desktopReady: Bool { !changingDesktop && runtimeReady && desktopAttached }
    var needsDesktopAttention: Bool { enabled && !changingDesktop && !desktopReady }
    var usesBridge: Bool { selectedProfileID != nil }
    var launchEnvironment: [String: String] {
        ["CODEX_CLI_PATH": Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/relay-cli").path,
         "CODEX_APP_SERVER_FORCE_CLI": "1", "CODEX_PROFILES_CLI": paths.cli]
    }

    func restore() {
        guard let value = UserDefaults.standard.string(forKey: "remote_profile"), let id = UUID(uuidString: value) else { return }
        do {
            try configure(id)
            if UserDefaults.standard.bool(forKey: "remote_enabled") { connect() }
        } catch { self.error = "Choose a saved account for your phone." }
    }

    private func configure(_ id: UUID) throws {
        guard let data = try savedCredentials?(id) else { throw RelayError.message("Choose a saved account.") }
        let identity = PhoneIdentity(paths: paths)
        try identity.useSavedProfile(data)
        identity.credentialProvider = { [weak self] in
            guard let self, self.selectedProfileID == id, let credentials = self.credentials else { throw CancellationError() }
            return try await credentials(id)
        }
        let installation = UserDefaults.standard.string(forKey: "remote_installation") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(installation, forKey: "remote_installation")
        let api = RemoteAPI(identity: identity, installationID: installation, name: "Codex Profiles · \(Host.current().localizedName ?? "Mac")")
        try api.restore()
        self.identity = identity; self.api = api; selectedProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: "remote_profile")
    }

    func select(_ id: UUID) {
        guard selectedProfileID != id else { return }
        do {
            // Validate before replacing a working selection.
            guard let data = try savedCredentials?(id) else { return }
            _ = try AccountProfile(data: data)
            disconnect()
            try configure(id)
            error = nil
            connect()
        } catch { self.error = error.localizedDescription }
    }

    func removeProfile(_ id: UUID) {
        guard selectedProfileID == id else { return }
        disconnect(); selectedProfileID = nil; identity = nil; api = nil
        UserDefaults.standard.removeObject(forKey: "remote_profile")
    }

    func connect() {
        guard let api, !enabled else { return }
        enabled = true; UserDefaults.standard.set(true, forKey: "remote_enabled")
        error = nil; startGateway(api)
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkRuntime()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }

    private func startGateway(_ api: RemoteAPI) {
        let gateway = Gateway(api: api, paths: paths)
        gateway.accountChoices = { [weak self] in self?.accountChoices?() ?? [] }
        gateway.refreshAccountLimits = { [weak self] in
            guard let refresh = self?.refreshAccountLimits else { return "The Mac app is unavailable." }
            return await refresh()
        }
        gateway.selectDesktopAccount = { [weak self] id in
            guard let self, let select = self.selectDesktopAccount else { return "The Mac app is unavailable." }
            return await select(id)
        }
        gateway.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .online: connected = true; status = "Connected"
            case .connecting: connected = false; status = "Connecting"
            case .retrying: connected = false; status = "Reconnecting"
            case .stopped: connected = false; status = "Disconnected"
            case .failed(let message): connected = false; status = "Needs attention"; error = message
            }
        }
        self.gateway = gateway; gateway.start()
    }

    func disconnect() {
        enabled = false; UserDefaults.standard.set(false, forKey: "remote_enabled")
        desktopGeneration = UUID(); attachedPID = nil; desktopAttached = false
        cancelPairing(); gateway?.stop(); gateway = nil; api?.cancelPendingEnrollment()
        monitorTask?.cancel(); monitorTask = nil; monitor?.close(); monitor = nil; runtimeReady = false
    }

    func toggleConnection() { enabled ? disconnect() : connect() }

    func prepareForDesktopChange() async throws {
        desktopGeneration = UUID()
        changingDesktop = true; attachedPID = nil; desktopAttached = false
        gateway?.stop(); gateway = nil
        monitor?.close(); monitor = nil; runtimeReady = false
        do { try await RuntimeProcess.stop(paths: paths) }
        catch { finishDesktopChange(); throw error }
    }

    func finishDesktopChange() {
        changingDesktop = false
        if enabled, gateway == nil, let api { startGateway(api) }
        Task { await checkRuntime() }
    }

    func refreshDesktopCredentials() async throws {
        guard let monitor else { throw RelayError.message("Open ChatGPT to renew the active session.") }
        _ = try await monitor.call("account/read", .object(["refreshToken": .bool(true)]))
    }

    @discardableResult func desktopIsAttached() async -> Bool {
        guard !changingDesktop else { return false }
        let generation = desktopGeneration
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }.map(\.processIdentifier)
        if let attachedPID, pids.contains(attachedPID), desktopAttached { return true }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/relay-cli").path
        let found: pid_t? = await Task.detached(priority: .utility) {
            guard !pids.isEmpty else { return nil }
            let probe = Process(), output = Pipe()
            probe.executableURL = URL(fileURLWithPath: "/bin/ps")
            probe.arguments = ["-axo", "ppid=,comm="]
            probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
            guard (try? probe.run()) != nil else { return nil }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            probe.waitUntilExit()
            return text.split(separator: "\n").compactMap { line -> pid_t? in
                let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2, fields[1] == helper, let pid = Int32(fields[0]), pids.contains(pid) else { return nil }
                return pid
            }.first
        }.value
        guard generation == desktopGeneration else { return false }
        attachedPID = found
        desktopAttached = found != nil
        return desktopAttached
    }

    private func checkRuntime() async {
        guard enabled, !changingDesktop else { return }
        await desktopIsAttached()
        guard enabled, !changingDesktop, monitor == nil,
              FileManager.default.fileExists(atPath: paths.socket.path) else { return }
        let channel = ProcessChannel()
        monitor = channel
        channel.onClose = { [weak self, weak channel] in
            guard self?.monitor === channel else { return }
            self?.monitor = nil; self?.runtimeReady = false
        }
        do {
            try channel.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
            _ = try await channel.initialize(name: "profiles_remote")
            if monitor === channel { runtimeReady = true }
        } catch {
            channel.close()
            if monitor === channel { monitor = nil; runtimeReady = false }
        }
    }

    func makePairing() {
        guard let api, !pairingBusy else { return }
        cancelPairing(); pairingBusy = true
        let window = RemotePairingWindow(model: self); pairingWindow = window; window.showWindow(nil)
        connect()
        pairingTask = Task {
            do {
                let value = try await api.pair(); try Task.checkCancellation()
                pairing = value; pairingBusy = false
                while value.expires > Date() {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let claimed = try await api.claimed(value)
                    try Task.checkCancellation()
                    if claimed { cancelPairing(); return }
                }
                pairing = nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled { pairingError = error.localizedDescription; pairingBusy = false } }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel(); pairingTask = nil
        let window = pairingWindow; pairingWindow = nil
        window?.window?.delegate = nil; window?.close()
        pairing = nil; pairingError = nil; pairingBusy = false
    }

    func shutdown() {
        let resume = enabled
        disconnect()
        UserDefaults.standard.set(resume, forKey: "remote_enabled")
    }
}
