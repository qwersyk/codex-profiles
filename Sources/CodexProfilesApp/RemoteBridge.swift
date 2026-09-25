import AppKit
import SwiftUI
import RelayCore
import CoreImage.CIFilterBuiltins
import Darwin

@MainActor
final class RemoteBridge: ObservableObject {
    @Published private(set) var phoneEmail: String?
    @Published private(set) var status = "Offline"
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var pairing: Pairing?
    @Published var error: String?
    @Published private(set) var peerCount = 0
    @Published private(set) var runtimeReady = false
    var profileOptions: (() -> [RemoteProfileOption])?
    var onProfileSwitch: ((UUID) async -> String?)?

    let paths = RelayPaths()
    private lazy var identity = PhoneIdentity(paths: paths)
    private lazy var api = RemoteAPI(identity: identity, installationID: Self.installationID,
                                     name: "Codex Profiles · \(Host.current().localizedName ?? "Mac")")
    private var gateway: Gateway?
    private var controlServer: LocalControlServer?
    private var pairingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var monitor: ProcessChannel?

    private static var installationID: String {
        if let value = UserDefaults.standard.string(forKey: "relayInstallationID") { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "relayInstallationID")
        return value
    }

    init() {
        do {
            try identity.restore()
            try api.restore()
            phoneEmail = identity.profile?.email
        } catch {
            self.error = "Choose a saved profile for phone access."
        }
        if phoneEmail != nil && UserDefaults.standard.bool(forKey: "relayRemoteEnabled") {
            connect()
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkRuntime()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func useProfile(id: UUID, email: String?, auth: Data) throws {
        let candidate = try AccountProfile(data: auth)
        let changed = identity.profile?.accountID != candidate.accountID
        stop()
        try identity.importProfile(auth)
        if changed { api.resetLocalEnrollment() }
        UserDefaults.standard.set(id.uuidString, forKey: "relayPhoneProfileID")
        phoneEmail = email ?? candidate.email
        error = nil
    }

    func selectedProfileID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: "relayPhoneProfileID") else { return nil }
        return UUID(uuidString: raw)
    }

    func start(phoneProfileID: UUID, email: String?, auth: Data) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            try useProfile(id: phoneProfileID, email: email, auth: auth)
            try await openDesktopWithRemote()
            connect()
            try await makePairing()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: "relayRemoteEnabled")
        pairingTask?.cancel(); pairingTask = nil; pairing = nil
        gateway?.stop(); gateway = nil
        controlServer?.stop(); controlServer = nil
        connected = false; status = "Offline"
    }

    private func connect() {
        guard phoneEmail != nil, gateway == nil else { return }
        UserDefaults.standard.set(true, forKey: "relayRemoteEnabled")
        let bridge = Gateway(api: api, paths: paths)
        gateway = bridge
        let control = LocalControlServer()
        control.profileOptions = { [weak self] in self?.profileOptions?() ?? [] }
        bridge.profileOptions = { [weak self] in self?.profileOptions?() ?? [] }
        bridge.onProfileSwitch = { [weak self] id in
            guard let self, let onProfileSwitch = self.onProfileSwitch else { return "The Mac app is unavailable." }
            return await onProfileSwitch(id)
        }
        control.onProfileSwitch = { [weak self] id in
            guard let self, let onProfileSwitch = self.onProfileSwitch else { return "The Mac app is unavailable." }
            return await onProfileSwitch(id)
        }
        control.start()
        controlServer = control
        bridge.profileControlURL = { [weak self] in self?.controlServer?.baseURL }
        bridge.onPeerCount = { [weak self] count in self?.peerCount = count }
        bridge.onDiagnostic = { [weak self] value in self?.status = value }
        bridge.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .stopped: self.status = "Offline"; self.connected = false
            case .connecting: self.status = "Connecting"; self.connected = false
            case .online: self.status = "Connected"; self.connected = true
            case .retrying(let seconds): self.status = "Retrying in \(seconds)s"; self.connected = false
            case .failed(let message): self.error = message; self.status = "Needs attention"; self.connected = false
            }
        }
        bridge.start()
        Task { [weak self] in
            do { try await self?.startRuntimeIfNeeded() }
            catch { self?.error = error.localizedDescription }
        }
    }

    private func startRuntimeIfNeeded() async throws {
        guard UserDefaults.standard.bool(forKey: "relayRemoteEnabled"),
              !FileManager.default.fileExists(atPath: paths.socket.path) else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/relay-cli")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw RelayError.message("Phone Remote is not installed in this app build.")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["app-server"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: paths.socket.path) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw RelayError.message("Codex runtime did not start for Remote.")
    }

    private func makePairing() async throws {
        pairingTask?.cancel()
        pairing = try await api.pair()
        guard let value = pairing else { return }
        pairingTask = Task { [weak self] in
            while !Task.isCancelled, value.expires > Date() {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self else { return }
                    if try await self.api.claimed(value) { self.pairing = nil; return }
                } catch { return }
            }
            self?.pairing = nil
        }
    }

    private func checkRuntime() async {
        guard monitor == nil, FileManager.default.fileExists(atPath: paths.socket.path) else {
            runtimeReady = FileManager.default.fileExists(atPath: paths.socket.path)
            return
        }
        let channel = ProcessChannel()
        do {
            try channel.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
            _ = try await channel.initialize(name: "profiles_remote_status")
            monitor = channel; runtimeReady = true
            channel.onClose = { [weak self] in self?.runtimeReady = false; self?.monitor = nil }
        } catch { channel.close(); runtimeReady = false }
    }

    func stopRuntimeForProfileSwitch() async throws {
        monitor?.close(); monitor = nil; runtimeReady = false
        guard FileManager.default.fileExists(atPath: paths.socket.path) else { return }
        guard let raw = try? String(contentsOf: paths.runtimePID, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            throw RelayError.message("Could not identify the Remote runtime to restart.")
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer) == URL(fileURLWithPath: paths.cli).resolvingSymlinksInPath().path else {
            throw RelayError.message("Remote runtime changed; reconnect Remote before switching profiles.")
        }
        guard kill(pid, SIGTERM) == 0 else {
            throw RelayError.message("Could not stop the previous Codex runtime.")
        }
        for _ in 0..<50 {
            if !FileManager.default.fileExists(atPath: paths.socket.path) || kill(pid, 0) != 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RelayError.message("The previous Codex runtime did not stop.")
    }

    func verifyRuntimeAccount(email: String?) async throws {
        guard let email, !email.isEmpty, UserDefaults.standard.bool(forKey: "relayRemoteEnabled") else { return }
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: paths.socket.path) {
                let channel = ProcessChannel()
                var observedEmail: String?
                do {
                    try channel.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
                    _ = try await channel.initialize(name: "profiles_switch_check")
                    let result = try await channel.call("account/read", .object(["refreshToken": .bool(false)]))
                    observedEmail = result["account"]["email"].string
                } catch { }
                channel.close()
                if let observedEmail {
                    guard observedEmail.caseInsensitiveCompare(email) == .orderedSame else {
                        throw RelayError.message("Codex reopened with a different account. Profile switch was not completed.")
                    }
                    return
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw RelayError.message("Could not verify the active Codex account after restart.")
    }

    private func openDesktopWithRemote() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/relay-cli")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw RelayError.message("Phone Remote is not installed in this app build.")
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }
        for app in apps { app.terminate() }
        for _ in 0..<100 {
            if apps.allSatisfy({ $0.isTerminated }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard apps.allSatisfy({ $0.isTerminated }) else {
            throw RelayError.message("ChatGPT could not quit. Finish any open dialog and try again.")
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            throw RelayError.message("Could not find the ChatGPT app.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["CODEX_CLI_PATH": helper.path, "CODEX_APP_SERVER_FORCE_CLI": "1"]
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        for _ in 0..<100 {
            await checkRuntime()
            if runtimeReady {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw RelayError.message("ChatGPT did not start its Remote service.")
    }

    func shutdown() {
        let resume = gateway != nil
        stop()
        UserDefaults.standard.set(resume, forKey: "relayRemoteEnabled")
        monitorTask?.cancel(); monitor?.close(); monitor = nil
    }
}

struct RelayPairingSheet: View {
    @ObservedObject var relay: RemoteBridge
    let profiles: [SavedProfile]
    let getAuth: (UUID) throws -> Data
    let close: () -> Void
    @State private var selectedID: UUID?
    @State private var qrImage: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            Text("ChatGPT Remote on Your Phone").font(.headline)
            Text(Gateway.virtualControlEnabled
                 ? "Pair ChatGPT Remote with this Mac. Relay adds a temporary Codex Profiles project with one Profiles & Limits control chat. It is generated in memory and is not saved as a Codex task. Open /accounts to see tappable profile links and limits; /use 2 remains available as a fallback."
                 : "Pass-through test: Remote shows the original Codex projects and chats. The profile control chat and its commands are temporarily disabled.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Picker("Phone account", selection: $selectedID) {
                Text("Choose a profile").tag(Optional<UUID>.none)
                ForEach(profiles) { profile in Text(profile.displayName).tag(Optional(profile.id)) }
            }
            .labelsHidden()
            .disabled(relay.busy || relay.connected)
            if let pairing = relay.pairing {
                if let qrImage {
                    Image(nsImage: qrImage).interpolation(.none).resizable().scaledToFit().frame(width: 210, height: 210)
                }
                Text("Scan with the ChatGPT app on your phone")
                    .font(.callout).multilineTextAlignment(.center)
                Text(pairing.manualCode ?? pairing.code).font(.system(.title2, design: .monospaced, weight: .semibold))
                Text("Expires \(pairing.expires.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if relay.busy {
                ProgressView("Starting Remote…")
            } else {
                Text(relay.connected ? "Remote bridge connected" : relay.status)
                    .font(.callout).foregroundStyle(relay.connected ? .green : .secondary)
            }
            if let error = relay.error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            HStack {
                if relay.connected || relay.pairing != nil {
                    Button("Stop Remote") { relay.stop() }
                }
                Spacer()
                Button("Connect & Pair") { start() }
                    .disabled(relay.busy || relay.connected || selectedID == nil)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 370)
        .onAppear { selectedID = relay.selectedProfileID() ?? profiles.first?.id }
        .onChange(of: relay.pairing?.code) { _ in
            guard let pairing = relay.pairing else { qrImage = nil; return }
            qrImage = Self.makeQR(for: pairing.url)
        }
    }

    private func start() {
        guard let selectedID, let profile = profiles.first(where: { $0.id == selectedID }) else { return }
        do {
            let data = try getAuth(selectedID)
            Task { await relay.start(phoneProfileID: selectedID, email: profile.email, auth: data) }
        } catch {
            relay.error = error.localizedDescription
        }
    }

    private static func makeQR(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output), image = NSImage(size: rep.size)
        image.addRepresentation(rep); return image
    }
}
