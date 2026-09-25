import SwiftUI

@main
struct CodexProfilesApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("show_menu_bar") private var showMenuBar = false
    @AppStorage("hide_emails") private var hideEmails = false
    @AppStorage("show_search") private var showSearch = false
    @AppStorage("renew_inactive_sessions") private var renewInactiveSessions = true
    @AppStorage("renewal_lead_days") private var renewalLeadDays = 1
    @AppStorage("sort_order") private var sortOrderRaw = SortOrder.recent.rawValue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private func shortcutTitle(_ row: ProfileRow) -> String {
        let name = hideEmails && row.title.contains("@") ? "Profile " + (row.shortcutNumber.map(String.init) ?? String(row.id.prefix(4))) : row.title
        return (row.isCurrent ? "✓ " : "") + name
    }

    var body: some Scene {
        Window("Codex Profiles", id: "profiles") {
            ContentView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.relayRemote.shutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if !model.isWorking { model.reload(); model.refreshUsage(all: true) }
                    }
                }
                .task {
                    appDelegate.setOpenHandler { urls in
                        Task { await model.importFiles(urls) }
                    }
                    model.startMaintenance()
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
                Toggle("Show in Menu Bar", isOn: $showMenuBar)
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
                Toggle("Renew Inactive Sessions Automatically", isOn: $renewInactiveSessions)
                    .help("Renew inactive sessions while this app is running. Does not extend subscriptions.")
                Picker("Renew Before Token Expiry", selection: $renewalLeadDays) {
                    ForEach(1...7, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .disabled(!renewInactiveSessions)
                Button("Refresh Current Limits") { model.reload(); model.refreshUsage(force: true) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isWorking)
                Button("Refresh All Limits") { model.reload(); model.refreshUsage(all: true, force: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
                Divider()
                Menu("Switch to Profile") {
                    ForEach(model.rows(sortedBy: SortOrder(rawValue: sortOrderRaw) ?? .recent).filter { $0.profileID != nil }) { row in
                        if let number = row.shortcutNumber {
                            Button(shortcutTitle(row)) { Task { await model.loadProfile(row) } }
                                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                                .disabled(model.isWorking || row.isCurrent)
                        } else {
                            Button(shortcutTitle(row)) { Task { await model.loadProfile(row) } }
                                .disabled(model.isWorking || row.isCurrent)
                        }
                    }
                }
                Button("Sign Out Locally") { Task { await model.logoutCodex() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
            }
        }
        MenuBarExtra("Codex Profiles", systemImage: "person.crop.rectangle.stack", isInserted: $showMenuBar) {
            ProfileMenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ProfileMenuBarView: View {
    @ObservedObject var model: AppModel
    @AppStorage("sort_order") private var sortOrderRaw = SortOrder.recent.rawValue
    @AppStorage("hide_emails") private var hideEmails = false
    @Environment(\.openWindow) private var openWindow
    @State private var hoveredProfileID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Codex Profiles").font(.headline)
                Spacer()
                Button { model.refreshUsage(all: true, force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).help("Refresh all limits")
                    .disabled(model.isWorking || !model.loadingUsage.isEmpty)
            }
            if model.profiles.isEmpty { Text("Save a profile in the main window.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.rows(sortedBy: SortOrder(rawValue: sortOrderRaw) ?? .recent).filter { $0.profileID != nil }) { row in
                        Button { Task { await model.loadProfile(row) } } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hideEmails && row.title.contains("@") ? "Profile " + String((model.rows(sortedBy: SortOrder(rawValue: sortOrderRaw) ?? .recent).firstIndex(where: { $0.id == row.id }) ?? 0) + 1) : row.title)
                                        .font(.subheadline.weight(.medium)).lineLimit(1)
                                    if let usage = row.usage, !usage.indicatorWindows.isEmpty {
                                        Text(usage.indicatorWindows.map { "\($0.durationLabel) · \(Int($0.remainingPercent))% left" }.joined(separator: "   ") + (usage.isStale ? " · cached" : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else { Text("Limits unavailable").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                ResetBadge(count: row.usage?.availableResets)
                                if let number = row.shortcutNumber {
                                    Text("⌘\(number)").font(.caption2).foregroundStyle(.tertiary)
                                }
                                if row.isSwitching {
                                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                            .background(Color.accentColor.opacity(hoveredProfileID == row.id && !model.isWorking ? 0.18 : row.isCurrent ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).disabled(model.isWorking)
                        .onHover { hovering in
                            if hovering { hoveredProfileID = row.id }
                            else if hoveredProfileID == row.id { hoveredProfileID = nil }
                        }
                        .help(row.isCurrent ? "Current profile" : "Switch and restart ChatGPT")
                    }
                }
            }
            // A menu-bar popover proposes an unconstrained height. A ScrollView's
            // intrinsic height is zero, so provide a concrete viewport for its rows.
            .frame(height: min(300, CGFloat(model.profiles.count) * 48))
            if model.switchingProfileID != nil { Text("Switching · restarting ChatGPT…").font(.caption).foregroundStyle(.secondary) }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            Divider()
            HStack {
                Button("Open Window") { openWindow(id: "profiles"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.disabled(model.isWorking)
            }
        }
        .padding(12).frame(width: 270)
        .task {
            // Present cached rows first; disk and network work must not delay the popover.
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            model.startMaintenance()
            model.refreshUsage(all: true)
        }
        .onDisappear { hoveredProfileID = nil }
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
