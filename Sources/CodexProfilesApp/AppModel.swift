import AppKit
import Foundation
import UniformTypeIdentifiers

struct SavedProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var customName: String?
    var email: String?
    var avatarSymbol: String?
    var avatarColorToken: String?
    let createdAt: Date
    var lastLoadedAt: Date?

    var displayName: String {
        if let customName = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !customName.isEmpty {
            return customName
        }
        if let email, !email.isEmpty {
            return email
        }
        return "Profile"
    }
}

struct CurrentProfileInfo: Equatable {
    var email: String?
    var isAvailable = false
}

struct ProfileRow: Identifiable, Equatable {
    let id: String
    let profileID: UUID?
    let title: String
    let email: String?
    let avatarSymbol: String?
    let avatarColorToken: String?
    let createdAt: Date?
    let lastLoadedAt: Date?
    let isCurrent: Bool
    let isUnsavedCurrent: Bool
}

enum SortOrder: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case created = "Created"
    case name = "Name"

    var id: String { rawValue }
}

struct NamePrompt: Identifiable {
    enum Mode {
        case add
        case rename(UUID)
    }

    let id = UUID()
    let mode: Mode
    let initialValue: String
    let initialAvatarSymbol: String
    let initialAvatarColorToken: String
}

enum AvatarOption: String, CaseIterable, Identifiable {
    case person = "person.crop.circle"
    case terminal = "terminal"
    case laptop = "laptopcomputer"
    case briefcase = "briefcase"
    case moon = "moon.stars"
    case sparkles = "sparkles"
    case flame = "flame"
    case bolt = "bolt.circle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .person: return "Person"
        case .terminal: return "Terminal"
        case .laptop: return "Laptop"
        case .briefcase: return "Briefcase"
        case .moon: return "Moon"
        case .sparkles: return "Sparkles"
        case .flame: return "Flame"
        case .bolt: return "Bolt"
        }
    }
}

enum AvatarTintOption: String, CaseIterable, Identifiable {
    case blue
    case graphite
    case green
    case orange
    case pink
    case red
    case teal

    var id: String { rawValue }
}

struct BrowserLoginState: Equatable {
    var message: String
    var authorizationURL: URL?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [SavedProfile] = []
    @Published private(set) var currentProfile = CurrentProfileInfo()
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var browserLogin: BrowserLoginState?

    private let store = ProfileStore()
    private var loginController: CodexLoginController?

    init() {
        reload()
    }

    func reload() {
        do {
            profiles = try store.loadProfiles()
            currentProfile = store.currentProfile()
        } catch {
            profiles = []
            currentProfile = store.currentProfile()
            errorMessage = error.localizedDescription
        }
    }

    func rows(sortedBy sortOrder: SortOrder) -> [ProfileRow] {
        let currentEmail = normalized(currentProfile.email)
        let savedRows = sortedProfiles(by: sortOrder).map { profile in
            let profileEmail = normalized(profile.email)
            return ProfileRow(
                id: profile.id.uuidString,
                profileID: profile.id,
                title: profile.displayName,
                email: profile.email,
                avatarSymbol: profile.avatarSymbol,
                avatarColorToken: profile.avatarColorToken,
                createdAt: profile.createdAt,
                lastLoadedAt: profile.lastLoadedAt,
                isCurrent: currentEmail != nil && currentEmail == profileEmail,
                isUnsavedCurrent: false
            )
        }

        let hasCurrentSaved = savedRows.contains(where: \.isCurrent)
        guard currentProfile.isAvailable, !hasCurrentSaved else {
            return savedRows
        }

        let currentTitle = currentProfile.email ?? "Current profile"
        let currentRow = ProfileRow(
            id: "current",
            profileID: nil,
            title: currentTitle,
            email: currentProfile.email,
            avatarSymbol: nil,
            avatarColorToken: nil,
            createdAt: nil,
            lastLoadedAt: nil,
            isCurrent: true,
            isUnsavedCurrent: true
        )

        return [currentRow] + savedRows
    }

    func addPromptIfNeeded() -> NamePrompt? {
        guard normalized(currentProfile.email) == nil else { return nil }
        return NamePrompt(
            mode: .add,
            initialValue: "Profile \(profiles.count + 1)",
            initialAvatarSymbol: AvatarOption.person.rawValue,
            initialAvatarColorToken: AvatarTintOption.blue.rawValue
        )
    }

    func renamePrompt(for row: ProfileRow) -> NamePrompt? {
        guard let id = row.profileID else { return nil }
        let currentName = profiles.first(where: { $0.id == id })?.customName ?? row.title
        return NamePrompt(
            mode: .rename(id),
            initialValue: currentName,
            initialAvatarSymbol: row.avatarSymbol ?? AvatarOption.person.rawValue,
            initialAvatarColorToken: row.avatarColorToken ?? AvatarTintOption.blue.rawValue
        )
    }

    func saveCurrentProfile(customName: String?, avatarSymbol: String?, avatarColorToken: String?) async {
        await runTask {
            _ = try self.store.captureCurrent(
                customName: customName,
                avatarSymbol: avatarSymbol,
                avatarColorToken: avatarColorToken,
                fallbackIndex: self.profiles.count + 1
            )
            self.reload()
        }
    }

    func startBrowserLoginProfile() async {
        guard loginController == nil else { return }

        errorMessage = nil
        browserLogin = BrowserLoginState(
            message: "Start sign in in your browser.",
            authorizationURL: nil
        )
        isWorking = true

        do {
            let controller = try CodexLoginController.start(codexCLIURL: try codexCLIURL()) { event in
                Task { @MainActor in
                    self.handleLoginEvent(event)
                }
            }
            loginController = controller
        } catch {
            browserLogin = nil
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }

    func cancelBrowserLogin() {
        loginController?.cancel()
        browserLogin = nil
    }

    func updateProfile(id: UUID, name: String, avatarSymbol: String, avatarColorToken: String) async {
        await runTask {
            try self.store.updateProfile(
                id: id,
                customName: name,
                avatarSymbol: avatarSymbol,
                avatarColorToken: avatarColorToken
            )
            self.reload()
        }
    }

    func deleteProfile(id: UUID) async {
        await runTask {
            try self.store.deleteProfile(id: id)
            self.reload()
        }
    }

    func loadProfile(_ row: ProfileRow) async {
        guard let id = row.profileID else { return }
        await runTask {
            let shouldRelaunch = try await self.quitCodexIfRunning()
            do {
                _ = try self.store.restoreProfile(id: id)
            } catch {
                if shouldRelaunch {
                    try? await self.launchCodex()
                }
                throw error
            }

            if shouldRelaunch {
                try await self.launchCodex()
            }
            self.reload()
        }
    }

    func logoutCodex() async {
        await runTask {
            let shouldRelaunch = try await self.quitCodexIfRunning()
            do {
                try self.runCodexLogout()
            } catch {
                if shouldRelaunch {
                    try? await self.launchCodex()
                }
                throw error
            }

            if shouldRelaunch {
                try await self.launchCodex()
            }
            self.reload()
        }
    }

    func importAuthFile(from url: URL) async {
        await runTask {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            _ = try self.store.importFile(from: url, fallbackIndex: self.profiles.count + 1)
            self.reload()
        }
    }

    func importProfileFromPanel() async {
        await runTask {
            guard let url = self.openPanel(title: "Import Profile") else { return }
            _ = try self.store.importFile(from: url, fallbackIndex: self.profiles.count + 1)
            self.reload()
        }
    }

    func importArchiveFromPanel() async {
        await runTask {
            guard let url = self.openPanel(title: "Import Backup") else { return }
            try self.store.importArchive(from: url)
            self.reload()
        }
    }

    func exportProfile(_ row: ProfileRow) async {
        guard let id = row.profileID else { return }

        await runTask {
            guard let url = self.savePanel(
                title: "Export Profile",
                suggestedName: "\(self.safeFilename(row.title)).codexprofile.json"
            ) else { return }
            try self.store.exportProfile(id: id, to: url)
        }
    }

    func exportAllProfiles() async {
        await runTask {
            guard let url = self.savePanel(
                title: "Export All Profiles",
                suggestedName: "Codex-Profiles-Backup.codexprofiles.json"
            ) else { return }
            try self.store.exportAll(to: url)
        }
    }

    private func sortedProfiles(by sortOrder: SortOrder) -> [SavedProfile] {
        switch sortOrder {
        case .recent:
            return profiles.sorted {
                let lhs = $0.lastLoadedAt ?? .distantPast
                let rhs = $1.lastLoadedAt ?? .distantPast
                if lhs == rhs { return $0.createdAt > $1.createdAt }
                return lhs > rhs
            }
        case .created:
            return profiles.sorted { $0.createdAt > $1.createdAt }
        case .name:
            return profiles.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runTask(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil

        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }

        isWorking = false
    }

    private func handleLoginEvent(_ event: CodexLoginEvent) {
        switch event {
        case .ready(let url):
            browserLogin?.message = "If the browser did not open, use this link."
            browserLogin?.authorizationURL = url
        case .finished(let exitCode, let stdout, let stderr, let wasCancelled):
            defer {
                loginController?.cleanup()
                loginController = nil
                browserLogin = nil
                isWorking = false
            }

            if wasCancelled {
                return
            }

            guard exitCode == 0 else {
                let details = [stderr, stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                errorMessage = StoreError.loginFailed(details?.isEmpty == false ? details : nil).localizedDescription
                return
            }

            guard let authURL = loginController?.authURL else {
                errorMessage = StoreError.loginFailed("Missing auth.json after login.").localizedDescription
                return
            }

            do {
                _ = try store.importFile(from: authURL, fallbackIndex: profiles.count + 1)
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func quitCodexIfRunning() async throws -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ProfileStore.codexBundleID)
        guard !running.isEmpty else { return false }

        for app in running {
            _ = app.terminate()
        }

        for _ in 0..<40 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: ProfileStore.codexBundleID).isEmpty {
                try await Task.sleep(nanoseconds: 500_000_000)
                return true
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw StoreError.codexDidNotQuit
    }

    private func launchCodex() async throws {
        let workspace = NSWorkspace.shared
        let appURL = try codexAppURL()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await workspace.openApplication(at: appURL, configuration: configuration)
    }

    private func runCodexLogout() throws {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = try codexCLIURL()
        process.arguments = ["logout"]
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw StoreError.logoutFailed(stderr?.isEmpty == false ? stderr! : (stdout?.isEmpty == false ? stdout! : nil))
        }
    }

    private func codexAppURL() throws -> URL {
        let workspace = NSWorkspace.shared
        let appURL = workspace.urlForApplication(withBundleIdentifier: ProfileStore.codexBundleID)
            ?? URL(fileURLWithPath: "/Applications/Codex.app")

        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw StoreError.codexMissing
        }
        return appURL
    }

    private func codexCLIURL() throws -> URL {
        let bundledCLI = try codexAppURL().appendingPathComponent("Contents/Resources/codex")
        if FileManager.default.fileExists(atPath: bundledCLI.path) {
            return bundledCLI
        }
        throw StoreError.codexCLIMissing
    }

    private func openPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func savePanel(title: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = value.components(separatedBy: invalid)
        let joined = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "Profile" : joined
    }
}

private enum StoreError: LocalizedError {
    case missingSource(String)
    case missingProfile
    case noProfilesToExport
    case codexDidNotQuit
    case codexMissing
    case codexCLIMissing
    case invalidAuthFile
    case invalidArchive
    case loginFailed(String?)
    case logoutFailed(String?)

    var errorDescription: String? {
        switch self {
        case .missingSource(let path):
            return "Missing file: \(path)"
        case .missingProfile:
            return "Profile not found."
        case .noProfilesToExport:
            return "No profiles to export."
        case .codexDidNotQuit:
            return "Codex did not quit. Quit it manually and try again."
        case .codexMissing:
            return "Codex.app not found."
        case .codexCLIMissing:
            return "Codex CLI not found inside Codex.app."
        case .invalidAuthFile:
            return "This is not a Codex auth JSON file."
        case .invalidArchive:
            return "This is not a Codex Profiles backup file."
        case .loginFailed(let details):
            return details?.isEmpty == false ? "Login failed: \(details!)" : "Login failed."
        case .logoutFailed(let details):
            return details?.isEmpty == false ? "Logout failed: \(details!)" : "Logout failed."
        }
    }
}

private struct ProfilesArchive: Codable {
    static let format = "codex-profiles-archive"

    let format: String
    let version: Int
    let exportedAt: Date
    let profiles: [ArchivedProfile]

    init(profiles: [ArchivedProfile]) {
        self.format = Self.format
        self.version = 1
        self.exportedAt = Date()
        self.profiles = profiles
    }
}

private struct ArchivedProfile: Codable {
    let customName: String?
    let email: String?
    let avatarSymbol: String?
    let avatarColorToken: String?
    let createdAt: Date
    let lastLoadedAt: Date?
    let authJSONString: String
}

private enum CodexLoginEvent {
    case ready(URL)
    case finished(Int32, String, String, Bool)
}

private final class CodexLoginController {
    let authURL: URL

    private let fileManager = FileManager.default
    private let process = Process()
    private let tempHomeURL: URL
    private let stdoutURL: URL
    private let stderrURL: URL
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let eventHandler: (CodexLoginEvent) -> Void
    private let lock = NSLock()
    private var didEmitURL = false
    private var wasCancelled = false
    private var pollTask: Task<Void, Never>?

    static func start(codexCLIURL: URL, eventHandler: @escaping (CodexLoginEvent) -> Void) throws -> CodexLoginController {
        let tempHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profiles-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHomeURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(
            at: tempHomeURL.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let stdoutURL = tempHomeURL.appendingPathComponent("login.stdout")
        let stderrURL = tempHomeURL.appendingPathComponent("login.stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)

        let controller = CodexLoginController(
            tempHomeURL: tempHomeURL,
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle,
            eventHandler: eventHandler
        )
        try controller.startProcess(codexCLIURL: codexCLIURL)
        return controller
    }

    private init(
        tempHomeURL: URL,
        stdoutURL: URL,
        stderrURL: URL,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        eventHandler: @escaping (CodexLoginEvent) -> Void
    ) {
        self.tempHomeURL = tempHomeURL
        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.eventHandler = eventHandler
        self.authURL = tempHomeURL.appendingPathComponent(".codex/auth.json")
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        lock.unlock()
        process.terminate()
    }

    func cleanup() {
        pollTask?.cancel()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        try? fileManager.removeItem(at: tempHomeURL)
    }

    private func startProcess(codexCLIURL: URL) throws {
        process.executableURL = codexCLIURL
        process.arguments = ["login", "-c", "auth_credentials_store_mode=\"file_storage\""]
        process.currentDirectoryURL = tempHomeURL
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.environment = processEnvironment()
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.pollTask?.cancel()
            self.emitLoginURLIfNeeded()
            let stdout = self.readText(from: self.stdoutURL)
            let stderr = self.readText(from: self.stderrURL)
            self.lock.lock()
            let wasCancelled = self.wasCancelled
            self.lock.unlock()
            self.eventHandler(.finished(process.terminationStatus, stdout, stderr, wasCancelled))
        }

        try process.run()
        pollTask = Task.detached { [weak self] in
            while let self, self.process.isRunning {
                self.emitLoginURLIfNeeded()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func emitLoginURLIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didEmitURL else { return }

        let text = readText(from: stderrURL)
        guard let url = extractFirstURL(from: text) else { return }

        didEmitURL = true
        eventHandler(.ready(url))
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempHomeURL.path
        environment["CODEX_HOME"] = tempHomeURL.appendingPathComponent(".codex").path
        return environment
    }

    private func readText(from url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func extractFirstURL(from text: String) -> URL? {
        let pattern = #"https://auth\.openai\.com/\S+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[range]))
    }
}

private final class ProfileStore {
    static let codexBundleID = "com.openai.codex"

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func loadProfiles() throws -> [SavedProfile] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        return try decoder.decode([SavedProfile].self, from: data)
    }

    func currentProfile() -> CurrentProfileInfo {
        guard
            fileManager.fileExists(atPath: authURL.path),
            let data = try? Data(contentsOf: authURL)
        else {
            return CurrentProfileInfo()
        }

        return CurrentProfileInfo(email: authEmail(from: data)?.lowercased(), isAvailable: true)
    }

    func captureCurrent(
        customName: String?,
        avatarSymbol: String?,
        avatarColorToken: String?,
        fallbackIndex: Int
    ) throws -> SavedProfile {
        var profiles = try loadProfiles()
        let current = currentProfile()
        let currentEmail = normalized(current.email)?.lowercased()
        let existingIndex = currentEmail.flatMap { email in
            profiles.firstIndex { normalized($0.email)?.lowercased() == email }
        }
        let snapshotID = existingIndex.map { profiles[$0].id } ?? UUID()
        let snapshotRoot = snapshotsURL.appendingPathComponent(snapshotID.uuidString, isDirectory: true)
        let snapshotAuthURL = self.snapshotAuthURL(for: snapshotID)

        do {
            if fileManager.fileExists(atPath: snapshotRoot.path) {
                try fileManager.removeItem(at: snapshotRoot)
            }
            try copy(from: authURL, to: snapshotAuthURL)

            let profile = SavedProfile(
                id: snapshotID,
                customName: normalized(customName)
                    ?? existingIndex.map { profiles[$0].customName }
                    ?? (current.email == nil ? "Profile \(fallbackIndex)" : nil),
                email: current.email,
                avatarSymbol: normalized(avatarSymbol)
                    ?? existingIndex.map { profiles[$0].avatarSymbol }
                    ?? AvatarOption.person.rawValue,
                avatarColorToken: normalized(avatarColorToken)
                    ?? existingIndex.map { profiles[$0].avatarColorToken }
                    ?? AvatarTintOption.blue.rawValue,
                createdAt: existingIndex.map { profiles[$0].createdAt } ?? Date(),
                lastLoadedAt: existingIndex.flatMap { profiles[$0].lastLoadedAt }
            )

            if let existingIndex {
                profiles[existingIndex] = profile
            } else {
                profiles.append(profile)
            }
            try save(profiles)
            return profile
        } catch {
            try? fileManager.removeItem(at: snapshotRoot)
            throw error
        }
    }

    func importAuthFile(from url: URL, fallbackIndex: Int) throws -> SavedProfile {
        let data = try Data(contentsOf: url)
        return try importAuthData(data, metadata: nil, fallbackIndex: fallbackIndex)
    }

    func importFile(from url: URL, fallbackIndex: Int) throws -> Int {
        let data = try Data(contentsOf: url)
        if let archive = try decodeArchive(from: data) {
            return try importArchive(archive)
        }

        _ = try importAuthData(data, metadata: nil, fallbackIndex: fallbackIndex)
        return 1
    }

    func importArchive(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let archive = try decodeArchive(from: data) else {
            throw StoreError.invalidArchive
        }
        _ = try importArchive(archive)
    }

    func exportProfile(id: UUID, to url: URL) throws {
        let profiles = try loadProfiles()
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw StoreError.missingProfile
        }

        let archived = try archivedProfile(for: profile)
        let archive = ProfilesArchive(profiles: [archived])
        let data = try encoder.encode(archive)
        try data.write(to: url, options: .atomic)
    }

    func exportAll(to url: URL) throws {
        let profiles = try loadProfiles()
        guard !profiles.isEmpty else {
            throw StoreError.noProfilesToExport
        }

        let archived = try profiles.map(archivedProfile(for:))
        let archive = ProfilesArchive(profiles: archived)
        let data = try encoder.encode(archive)
        try data.write(to: url, options: .atomic)
    }

    func updateProfile(
        id: UUID,
        customName: String,
        avatarSymbol: String,
        avatarColorToken: String
    ) throws {
        var profiles = try loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.missingProfile
        }

        profiles[index].customName = normalized(customName)
        profiles[index].avatarSymbol = normalized(avatarSymbol) ?? AvatarOption.person.rawValue
        profiles[index].avatarColorToken = normalized(avatarColorToken) ?? AvatarTintOption.blue.rawValue
        try save(profiles)
    }

    func deleteProfile(id: UUID) throws {
        var profiles = try loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.missingProfile
        }

        let snapshotRoot = snapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let legacySnapshotRoot = legacySnapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: snapshotRoot.path) {
            try fileManager.removeItem(at: snapshotRoot)
        }
        if fileManager.fileExists(atPath: legacySnapshotRoot.path) {
            try fileManager.removeItem(at: legacySnapshotRoot)
        }

        profiles.remove(at: index)
        try save(profiles)
    }

    func restoreProfile(id: UUID) throws -> SavedProfile {
        var profiles = try loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.missingProfile
        }

        let source = try existingAuthURL(for: id)
        try copy(from: source, to: authURL)

        profiles[index].lastLoadedAt = Date()
        try save(profiles)
        return profiles[index]
    }

    private var homeURL: URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private var storageURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeURL.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Codex Profiles", isDirectory: true)
    }

    private var snapshotsURL: URL {
        storageURL.appendingPathComponent("Snapshots", isDirectory: true)
    }

    private var legacySnapshotsURL: URL {
        storageURL.appendingPathComponent("Profiles", isDirectory: true)
    }

    private var indexURL: URL {
        storageURL.appendingPathComponent("profiles.json")
    }

    private var authURL: URL {
        homeURL.appendingPathComponent(".codex/auth.json")
    }

    private func snapshotAuthURL(for id: UUID) -> URL {
        snapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(".codex/auth.json")
    }

    private func existingAuthURL(for id: UUID) throws -> URL {
        let currentURL = snapshotAuthURL(for: id)
        if fileManager.fileExists(atPath: currentURL.path) {
            return currentURL
        }

        let legacyURL = legacySnapshotsURL
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(".codex/auth.json")
        if fileManager.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }

        throw StoreError.missingSource(currentURL.path)
    }

    private func save(_ profiles: [SavedProfile]) throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(profiles)
        try data.write(to: indexURL, options: .atomic)
    }

    private func importArchive(_ archive: ProfilesArchive) throws -> Int {
        guard archive.format == ProfilesArchive.format else {
            throw StoreError.invalidArchive
        }

        for (offset, archived) in archive.profiles.enumerated() {
            let data = Data(archived.authJSONString.utf8)
            _ = try importAuthData(
                data,
                metadata: archived,
                fallbackIndex: offset + 1
            )
        }
        return archive.profiles.count
    }

    private func decodeArchive(from data: Data) throws -> ProfilesArchive? {
        guard let archive = try? decoder.decode(ProfilesArchive.self, from: data) else {
            return nil
        }
        guard archive.format == ProfilesArchive.format else {
            throw StoreError.invalidArchive
        }
        return archive
    }

    private func importAuthData(
        _ data: Data,
        metadata: ArchivedProfile?,
        fallbackIndex: Int
    ) throws -> SavedProfile {
        guard isCodexAuth(data) else {
            throw StoreError.invalidAuthFile
        }

        var profiles = try loadProfiles()
        let email = authEmail(from: data)?.lowercased() ?? metadata?.email?.lowercased()
        let existingIndex = normalized(email).flatMap { importedEmail in
            profiles.firstIndex { normalized($0.email)?.lowercased() == importedEmail }
        }
        let snapshotID = existingIndex.map { profiles[$0].id } ?? UUID()
        let snapshotRoot = snapshotsURL.appendingPathComponent(snapshotID.uuidString, isDirectory: true)
        let authDestination = snapshotAuthURL(for: snapshotID)

        do {
            if fileManager.fileExists(atPath: snapshotRoot.path) {
                try fileManager.removeItem(at: snapshotRoot)
            }
            try fileManager.createDirectory(
                at: authDestination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: authDestination, options: .atomic)

            let profile = SavedProfile(
                id: snapshotID,
                customName: metadata?.customName
                    ?? existingIndex.map { profiles[$0].customName }
                    ?? email
                    ?? "Profile \(fallbackIndex)",
                email: email,
                avatarSymbol: metadata?.avatarSymbol
                    ?? existingIndex.map { profiles[$0].avatarSymbol }
                    ?? AvatarOption.person.rawValue,
                avatarColorToken: metadata?.avatarColorToken
                    ?? existingIndex.map { profiles[$0].avatarColorToken }
                    ?? AvatarTintOption.blue.rawValue,
                createdAt: metadata?.createdAt
                    ?? existingIndex.map { profiles[$0].createdAt }
                    ?? Date(),
                lastLoadedAt: metadata?.lastLoadedAt
                    ?? existingIndex.flatMap { profiles[$0].lastLoadedAt }
            )

            if let existingIndex {
                profiles[existingIndex] = profile
            } else {
                profiles.append(profile)
            }
            try save(profiles)
            return profile
        } catch {
            try? fileManager.removeItem(at: snapshotRoot)
            throw error
        }
    }

    private func archivedProfile(for profile: SavedProfile) throws -> ArchivedProfile {
        let authData = try Data(contentsOf: existingAuthURL(for: profile.id))
        guard let authJSONString = String(data: authData, encoding: .utf8) else {
            throw StoreError.invalidAuthFile
        }

        return ArchivedProfile(
            customName: profile.customName,
            email: profile.email,
            avatarSymbol: profile.avatarSymbol,
            avatarColorToken: profile.avatarColorToken,
            createdAt: profile.createdAt,
            lastLoadedAt: profile.lastLoadedAt,
            authJSONString: authJSONString
        )
    }

    private func copy(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw StoreError.missingSource(source.path)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodePayload(token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }

        guard
            let data = Data(base64Encoded: base64),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return payload
    }

    private func isCodexAuth(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let tokens = json["tokens"] as? [String: Any]
        let hasChatGPTToken = normalized(tokens?["refresh_token"] as? String) != nil
            || normalized(tokens?["access_token"] as? String) != nil
            || normalized(tokens?["id_token"] as? String) != nil
        let hasAPIKey = normalized(json["OPENAI_API_KEY"] as? String) != nil
        return hasChatGPTToken || hasAPIKey
    }

    private func authEmail(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let tokens = json["tokens"] as? [String: Any]
        let idPayload = decodePayload(token: tokens?["id_token"] as? String)
        let accessPayload = decodePayload(token: tokens?["access_token"] as? String)

        return stringValue(from: idPayload, key: "email")
            ?? stringValue(from: accessPayload, path: ["https://api.openai.com/profile", "email"])
    }

    private func stringValue(from payload: [String: Any]?, key: String) -> String? {
        payload?[key] as? String
    }

    private func stringValue(from payload: [String: Any]?, path: [String]) -> String? {
        guard let first = path.first else { return nil }
        if path.count == 1 {
            return payload?[first] as? String
        }
        return stringValue(from: payload?[first] as? [String: Any], path: Array(path.dropFirst()))
    }
}
