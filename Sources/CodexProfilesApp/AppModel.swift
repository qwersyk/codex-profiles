import AppKit
import Foundation

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

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [SavedProfile] = []
    @Published private(set) var currentProfile = CurrentProfileInfo()
    @Published var isWorking = false
    @Published var errorMessage: String?

    private let store = ProfileStore()

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
            try await self.closeCodexIfNeeded()
            _ = try self.store.restoreProfile(id: id)
            self.reload()
            try await self.launchCodex()
            self.reload()
        }
    }

    func restartCodex() async {
        await runTask {
            try await self.closeCodexIfNeeded()
            try await self.launchCodex()
            self.reload()
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

    private func closeCodexIfNeeded() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ProfileStore.codexBundleID)
        guard !running.isEmpty else { return }

        for app in running {
            _ = app.terminate()
        }

        for _ in 0..<20 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: ProfileStore.codexBundleID).isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: ProfileStore.codexBundleID) {
            _ = app.forceTerminate()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func launchCodex() async throws {
        let workspace = NSWorkspace.shared
        let appURL = workspace.urlForApplication(withBundleIdentifier: ProfileStore.codexBundleID)
            ?? URL(fileURLWithPath: "/Applications/Codex.app")

        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw StoreError.codexMissing
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await workspace.openApplication(at: appURL, configuration: configuration)
    }
}

private enum StoreError: LocalizedError {
    case missingSource(String)
    case missingProfile
    case codexMissing

    var errorDescription: String? {
        switch self {
        case .missingSource(let path):
            return "Missing file: \(path)"
        case .missingProfile:
            return "Profile not found."
        case .codexMissing:
            return "Codex.app not found."
        }
    }
}

private struct SnapshotFile {
    let liveURL: URL
    let relativePath: String
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
        let authURL = homeURL.appendingPathComponent(".codex/auth.json")
        guard
            fileManager.fileExists(atPath: authURL.path),
            let data = try? Data(contentsOf: authURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return CurrentProfileInfo()
        }

        let tokens = json["tokens"] as? [String: Any]
        let idPayload = decodePayload(token: tokens?["id_token"] as? String)
        let accessPayload = decodePayload(token: tokens?["access_token"] as? String)

        let email = stringValue(from: idPayload, key: "email")
            ?? stringValue(from: accessPayload, path: ["https://api.openai.com/profile", "email"])

        return CurrentProfileInfo(email: email?.lowercased(), isAvailable: true)
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

        do {
            if fileManager.fileExists(atPath: snapshotRoot.path) {
                try fileManager.removeItem(at: snapshotRoot)
            }
            try fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: true, attributes: nil)
            for file in snapshotFiles {
                try copy(from: file.liveURL, to: snapshotRoot.appendingPathComponent(file.relativePath))
            }

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
                createdAt: Date(),
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
        if fileManager.fileExists(atPath: snapshotRoot.path) {
            try fileManager.removeItem(at: snapshotRoot)
        }

        profiles.remove(at: index)
        try save(profiles)
    }

    func restoreProfile(id: UUID) throws -> SavedProfile {
        var profiles = try loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.missingProfile
        }

        let snapshotRoot = snapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
        for file in snapshotFiles {
            let source = snapshotRoot.appendingPathComponent(file.relativePath)
            try copy(from: source, to: file.liveURL)
        }

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

    private var indexURL: URL {
        storageURL.appendingPathComponent("profiles.json")
    }

    private var snapshotFiles: [SnapshotFile] {
        [
            SnapshotFile(
                liveURL: homeURL.appendingPathComponent(".codex/auth.json"),
                relativePath: ".codex/auth.json"
            ),
            SnapshotFile(
                liveURL: homeURL.appendingPathComponent(".codex/config.toml"),
                relativePath: ".codex/config.toml"
            ),
        ]
    }

    private func save(_ profiles: [SavedProfile]) throws {
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(profiles)
        try data.write(to: indexURL, options: .atomic)
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
