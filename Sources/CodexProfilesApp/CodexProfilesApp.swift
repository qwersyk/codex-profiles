import SwiftUI

@main
struct CodexProfilesApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("hide_emails") private var hideEmails = false
    @AppStorage("show_search") private var showSearch = false
    @AppStorage("sort_order") private var sortOrderRaw = SortOrder.recent.rawValue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Codex Profiles", id: "profiles") {
            ContentView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if !model.isWorking { model.reload() }
                }
                .task {
                    appDelegate.setOpenHandler { urls in
                        Task { await model.importFiles(urls) }
                    }
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
                        model.synchronizeSavedSession()
                    }
                }
        }
        .defaultSize(width: 560, height: 430)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Save Current Profile") {
                    NotificationCenter.default.post(name: .saveCurrentProfile, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isWorking || !model.currentProfile.isAvailable)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Hide Email Addresses", isOn: $hideEmails)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Toggle("Show Search", isOn: $showSearch)
                    .keyboardShortcut("f", modifiers: .command)
                Picker("Sort Profiles", selection: $sortOrderRaw) {
                    ForEach(SortOrder.allCases) { order in Text(order.rawValue).tag(order.rawValue) }
                }
            }
            CommandMenu("Profiles") {
                Button("Sign In New Profile") { Task { await model.startBrowserLoginProfile() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
                Button("Import Profile…") { Task { await model.importProfileFromPanel() } }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(model.isWorking)
                Button("Import Backup…") { Task { await model.importArchiveFromPanel() } }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
                Button("Export All…") { Task { await model.exportAllProfiles() } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
                Divider()
                Button("Refresh") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isWorking)
                Button("Sign Out Locally") { Task { await model.logoutCodex() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var openHandler: (([URL]) -> Void)?

    func setOpenHandler(_ handler: @escaping ([URL]) -> Void) {
        openHandler = handler
        flushPendingURLs()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueue(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func enqueue(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        if let openHandler {
            openHandler(fileURLs)
        } else {
            pendingURLs.append(contentsOf: fileURLs)
        }
    }

    private func flushPendingURLs() {
        guard let openHandler, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        openHandler(urls)
    }
}

extension Notification.Name {
    static let saveCurrentProfile = Notification.Name("saveCurrentProfile")
}
