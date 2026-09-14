import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    @AppStorage("hide_emails") private var hideEmails = false
    @State private var searchText = ""
    @AppStorage("show_search") private var showSearch = false
    @State private var sessionRow: ProfileRow?
    @FocusState private var searchFocused: Bool
    @AppStorage("sort_order") private var sortOrderRaw = SortOrder.recent.rawValue
    @State private var prompt: NamePrompt?
    @State private var draftName = ""
    @State private var draftAvatarSymbol = AvatarOption.person.rawValue
    @State private var draftAvatarColorToken = AvatarTintOption.blue.rawValue
    @State private var isDropTargeted = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(rows) { row in
                    ProfileRowView(
                        row: row,
                        hideEmails: hideEmails,
                        canRenew: model.canRenew(row),
                        isBusy: model.isWorking,
                        renameAction: {
                            guard let prompt = model.renamePrompt(for: row) else { return }
                            self.prompt = prompt
                            draftName = prompt.initialValue
                            draftAvatarSymbol = prompt.initialAvatarSymbol
                            draftAvatarColorToken = prompt.initialAvatarColorToken
                        },
                        loadAction: {
                            Task { await model.loadProfile(row) }
                        },
                        deleteAction: {
                            guard let id = row.profileID else { return }
                            Task { await model.deleteProfile(id: id) }
                        },
                        exportAction: {
                            Task { await model.exportProfile(row) }
                        },
                        detailsAction: { sessionRow = row },
                        renewAction: {
                            sessionRow = row
                            if let id = row.profileID { Task { await model.renewSession(id: id) } }
                        },
                        signInAction: { Task { await model.startBrowserLoginProfile() } },
                        addAction: {
                            Task { await addCurrentProfile() }
                        }
                    )
                }

                if rows.isEmpty {
                    Text(searchText.isEmpty ? "No saved profiles" : "No matching profiles")
                        .font(.headline)
                    Text("Sign in to add an account, or import a profile backup.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 300)
        .safeAreaInset(edge: .top) {
            if showSearch {
                TextField("Search profiles", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .onChange(of: showSearch) { visible in
            if visible { searchFocused = true } else { searchText = "" }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .padding(10)
                .opacity(isDropTargeted ? 0.9 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.startBrowserLoginProfile() }
                } label: {
                    Label("Sign In New Profile", systemImage: "person.crop.circle.badge.plus")
                }
                .help("Add account with browser sign-in (⇧⌘N)")
                .disabled(model.isWorking)
                Button {
                    Task { await addCurrentProfile() }
                } label: {
                    Label("Save Current Profile", systemImage: "tray.and.arrow.down")
                }
                .disabled(model.isWorking || !model.currentProfile.isAvailable)
                .help("Save current profile (⌘S)")
                Button {
                    Task { await model.importProfileFromPanel() }
                } label: {
                    Label("Import Profiles", systemImage: "square.and.arrow.down")
                }
                .help("Import profiles or backup (⌘I)")
                .disabled(model.isWorking)
                Button {
                    Task { await model.logoutCodex() }
                } label: {
                    Label("Sign Out Locally", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(model.isWorking || !model.currentProfile.isAvailable)
                .help("Sign out locally, preserving the saved session")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isWorking || !model.loadingUsage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    Text(model.switchingProfileID != nil ? "Switching profile · restarting ChatGPT…" : model.isWorking ? "Working…" : "Updating limits…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .disabled(model.isWorking && !model.isRenewingSession)
        .onReceive(NotificationCenter.default.publisher(for: .saveCurrentProfile)) { _ in
            guard !model.isWorking, prompt == nil else { return }
            Task { await addCurrentProfile() }
        }
        .sheet(item: $sessionRow) { row in
            SessionDetailsView(model: model, row: row, close: { sessionRow = nil }, signIn: {
                sessionRow = nil
                Task { await model.startBrowserLoginProfile() }
            })
        }
        .sheet(item: $prompt) { prompt in
            NamePromptView(
                draftName: $draftName,
                draftAvatarSymbol: $draftAvatarSymbol,
                draftAvatarColorToken: $draftAvatarColorToken,
                confirmAction: { submit(prompt) },
                cancelAction: {
                    self.prompt = nil
                    self.draftName = ""
                    self.draftAvatarSymbol = AvatarOption.person.rawValue
                    self.draftAvatarColorToken = AvatarTintOption.blue.rawValue
                }
            )
            .focused($nameFocused)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    nameFocused = true
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.browserLogin != nil },
                set: { if !$0 { model.cancelBrowserLogin() } }
            )
        ) {
            if let login = model.browserLogin {
                BrowserLoginView(
                    state: login,
                    openAction: {
                        if let url = login.authorizationURL {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    cancelAction: {
                        model.cancelBrowserLogin()
                    }
                )
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var rows: [ProfileRow] {
        model.rows(sortedBy: selectedSortOrder.wrappedValue).filter { row in
            searchText.isEmpty || row.title.localizedCaseInsensitiveContains(searchText) || (!hideEmails && (row.email?.localizedCaseInsensitiveContains(searchText) ?? false))
        }
    }

    private var selectedSortOrder: Binding<SortOrder> {
        Binding(
            get: { SortOrder(rawValue: sortOrderRaw) ?? .recent },
            set: { sortOrderRaw = $0.rawValue }
        )
    }

    private func addCurrentProfile() async {
        if let prompt = model.addPromptIfNeeded() {
            self.prompt = prompt
            draftName = prompt.initialValue
            draftAvatarSymbol = prompt.initialAvatarSymbol
            draftAvatarColorToken = prompt.initialAvatarColorToken
            return
        }
        await model.saveCurrentProfile(customName: nil, avatarSymbol: nil, avatarColorToken: nil)
    }

    private func submit(_ prompt: NamePrompt) {
        let current = prompt
        self.prompt = nil

        Task {
            switch current.mode {
            case .add:
                await model.saveCurrentProfile(
                    customName: draftName,
                    avatarSymbol: draftAvatarSymbol,
                    avatarColorToken: draftAvatarColorToken
                )
            case .rename(let id):
                await model.updateProfile(
                    id: id,
                    name: draftName,
                    avatarSymbol: draftAvatarSymbol,
                    avatarColorToken: draftAvatarColorToken
                )
            }
            draftName = ""
            draftAvatarSymbol = AvatarOption.person.rawValue
            draftAvatarColorToken = AvatarTintOption.blue.rawValue
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = droppedURL(from: item), url.isFileURL else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task { await model.importFiles(urls) }
        }

        return true
    }

    private func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String, let url = URL(string: string), url.isFileURL {
            return url
        }
        return nil
    }
}

private struct ProfileRowView: View {
    let row: ProfileRow
    let hideEmails: Bool
    let canRenew: Bool
    let isBusy: Bool
    @State private var confirmDelete = false
    let renameAction: () -> Void
    let loadAction: () -> Void
    let deleteAction: () -> Void
    let exportAction: () -> Void
    let detailsAction: () -> Void
    let renewAction: () -> Void
    let signInAction: () -> Void
    let addAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            avatarCircle(
                symbol: row.isUnsavedCurrent ? "person.crop.circle.badge.plus" : (row.avatarSymbol ?? AvatarOption.person.rawValue),
                tint: row.isUnsavedCurrent ? .secondary : avatarTint(row.avatarColorToken)
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hideEmails && (row.title.contains("@") || row.title == row.email) ? "Profile" : row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if !row.isUnsavedCurrent && !showsSecondaryEmail {
                        editButton
                    }
                    if let plan = row.plan {
                        Text(plan)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(plan == "Free" ? Color.secondary : Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((plan == "Free" ? Color.secondary : Color.accentColor).opacity(0.1), in: Capsule())
                            .fixedSize()
                            .help("Plan from saved account information")
                    }
                    if let warning = row.renewalWarning {
                        Button(action: detailsAction) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help(warning)
                        .accessibilityLabel("Session renewal needs attention")
                    }
                }

                HStack(spacing: 8) {
                    if let email = row.email, showsSecondaryEmail {
                        Text(hideEmails ? "Email hidden" : email)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        editButton
                    } else if row.isUnsavedCurrent {
                        Text("Not saved")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    if let number = row.shortcutNumber {
                        Text("⌘\(number)").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help("Switch directly to this profile while Codex Profiles is active")
                    }
                    if let createdAt = row.createdAt {
                        MetaChip(symbol: "square.and.arrow.down", text: compactDate(createdAt))
                    }
                    if let lastLoadedAt = row.lastLoadedAt {
                        MetaChip(symbol: "clock", text: compactDate(lastLoadedAt))
                    }
                }
            }

            Spacer(minLength: 6)

            if row.isUnsavedCurrent {
                IconPill(symbol: "plus", action: addAction, help: "Save Current Profile")
                    .disabled(isBusy)
            } else {
                HStack(spacing: 6) {
                    ProfileActionsMenu(actions: [
                        .init(title: "Edit Profile", symbol: "pencil", enabled: !isBusy, action: renameAction),
                        .init(title: "Export Profile", symbol: "square.and.arrow.up", enabled: !isBusy, action: exportAction),
                        .init(title: "Session & Limits…", symbol: "info.circle", action: detailsAction),
                        .init(title: "Renew Session", symbol: "arrow.clockwise", enabled: canRenew && !isBusy, action: renewAction),
                        .init(title: "Sign In Again…", symbol: "person.crop.circle.badge.plus", enabled: !isBusy, action: signInAction),
                        .init(title: "Delete Profile…", symbol: "trash", enabled: !isBusy, action: { confirmDelete = true })
                    ])
                    .frame(width: 28, height: 28)
                    ResetBadge(count: row.usage?.availableResets)
                    QuotaSwitch(row: row, isBusy: isBusy, action: loadAction)
                }
            }
        }
        .alert("Delete saved profile?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteAction)
        } message: {
            Text("This removes the saved copy from this app. Your current ChatGPT session remains available.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(border, lineWidth: row.isCurrent ? 1 : 0.8)
                .allowsHitTesting(false)
        )
    }

    private var background: Color {
        if row.isCurrent {
            return Color.accentColor.opacity(row.isUnsavedCurrent ? 0.05 : 0.09)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var border: Color {
        if row.isCurrent {
            return Color.accentColor.opacity(row.isUnsavedCurrent ? 0.22 : 0.45)
        }
        return Color.primary.opacity(0.08)
    }

    private func compactDate(_ date: Date) -> String {
        CompactDateFormatter.shared.string(from: date)
    }

    private var showsSecondaryEmail: Bool {
        if let email = row.email {
            return email != row.title
        }
        return false
    }

    private func avatarCircle(symbol: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 30, height: 30)
    }

    private func avatarTint(_ token: String?) -> Color {
        switch AvatarTintOption(rawValue: token ?? "") ?? .blue {
        case .blue: return .blue
        case .graphite: return .gray
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .red: return .red
        case .teal: return .teal
        }
    }

    private var editButton: some View {
        Button(action: renameAction) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Edit")
        .disabled(isBusy)
    }
}

private struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}

struct ResetBadge: View {
    let count: Int?

    var body: some View {
        if let count, count > 0 {
            Text(String(count))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .fixedSize()
                .help("Available limit resets: \(count)")
                .accessibilityLabel("\(count) available limit resets")
        }
    }
}

func quotaColor(_ remaining: Double) -> Color {
    remaining <= 10 ? .red : remaining <= 30 ? .orange : .green
}

// Start at twelve o'clock and follow the perimeter clockwise.
private struct ClockwiseQuotaBorder: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = min(9, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct QuotaSwitch: View {
    let row: ProfileRow
    let isBusy: Bool
    let action: () -> Void

    private var windows: [UsageWindow] { row.usage?.indicatorWindows ?? [] }
    private var hint: String {
        var text = row.isSwitching ? "Switching profile…" : row.isCurrent ? "Current profile" : "Switch to this profile (restarts ChatGPT)"
        for window in windows { text += "\n\(window.durationLabel): \(Int(window.remainingPercent))% remaining" }
        if let usage = row.usage {
            text += "\nUpdated \(usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
            if usage.isStale { text += " · cached" }
            if let count = usage.availableResets { text += "\nAvailable resets: \(count)" }
        } else { text += "\nLimits not loaded" }
        return text
    }

    var body: some View {
        Button { if !row.isCurrent { action() } } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.08))
                if let first = windows.first {
                    quotaColor(first.remainingPercent).opacity(row.usage?.isStale == true ? 0.2 : 0.4)
                        .frame(height: 32 * first.remainingPercent / 100)
                }
                Image(systemName: row.isSwitching ? "ellipsis" : row.isCurrent ? "checkmark" : "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                if windows.count > 1, let last = windows.last {
                    RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12), lineWidth: 2)
                    ClockwiseQuotaBorder().trim(from: 0, to: last.remainingPercent / 100)
                        .stroke(quotaColor(last.remainingPercent).opacity(row.usage?.isStale == true ? 0.35 : 1), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(hint)
        .accessibilityLabel(hint)
    }
}

private struct IconPill: View {
    let symbol: String
    let action: () -> Void
    let help: String

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct NamePromptView: View {
    @Binding var draftName: String
    @Binding var draftAvatarSymbol: String
    @Binding var draftAvatarColorToken: String
    let confirmAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(AvatarOption.allCases) { option in
                    Button {
                        draftAvatarSymbol = option.rawValue
                    } label: {
                        Image(systemName: option.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(
                                (draftAvatarSymbol == option.rawValue ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                ForEach(AvatarTintOption.allCases) { option in
                    Button {
                        draftAvatarColorToken = option.rawValue
                    } label: {
                        Circle()
                            .fill(tintColor(option))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        draftAvatarColorToken == option.rawValue ? Color.primary.opacity(0.8) : .clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel", action: cancelAction)
                .keyboardShortcut(.cancelAction)

                Button("Save", action: confirmAction)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 280)
    }

    private func tintColor(_ option: AvatarTintOption) -> Color {
        switch option {
        case .blue: return .blue
        case .graphite: return .gray
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .red: return .red
        case .teal: return .teal
        }
    }
}

private struct BrowserLoginView: View {
    let state: BrowserLoginState
    let openAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)

            Text(state.message)
                .font(.system(size: 13, weight: .medium))

            if let url = state.authorizationURL {
                Text(url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel", action: cancelAction)
                .keyboardShortcut(.cancelAction)

                if state.authorizationURL != nil {
                    Button(action: openAction) {
                        Image(systemName: "arrow.up.forward.app")
                            .frame(width: 28, height: 28)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

private enum CompactDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter
    }()
}

/// A real macOS menu with a full button hit area and no disclosure arrow.
private struct ProfileActionsMenu: NSViewRepresentable {
    struct Action {
        let title: String
        let symbol: String
        var enabled = true
        let action: () -> Void
    }
    let actions: [Action]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Profile actions")!,
                              target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = "Profile actions"
        button.setAccessibilityLabel("Profile actions")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.actions = actions
        button.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var actions: [Action] = []
        private var displayedActions: [Action] = []

        @objc func showMenu(_ sender: NSButton) {
            displayedActions = actions
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, action) in displayedActions.enumerated() {
                if index == displayedActions.count - 1 { menu.addItem(.separator()) }
                let item = NSMenuItem(title: action.title, action: #selector(invoke(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.isEnabled = action.enabled
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc func invoke(_ sender: NSMenuItem) {
            guard displayedActions.indices.contains(sender.tag) else { return }
            let action = displayedActions[sender.tag].action
            DispatchQueue.main.async(execute: action)
        }
    }
}

private struct SessionDetailsView: View {
    @ObservedObject var model: AppModel
    let row: ProfileRow
    let close: () -> Void
    let signIn: () -> Void
    @State private var showTechnical = false

    private var overview: SessionOverview { model.sessionOverview(for: row) }
    private var usageError: String? { row.profileID.flatMap { model.usageErrors[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Session Details").font(.headline)
                Spacer()
                if let plan = overview.plan { Text(plan).font(.subheadline).foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(overview.requiresSignIn ? "Sign-in required" : overview.renewalFailed ? "Renewal failed" : row.isCurrent ? "Active in ChatGPT" : "Saved session",
                          systemImage: overview.requiresSignIn || overview.renewalFailed ? "exclamationmark.circle" : "person.crop.circle")
                        .foregroundStyle(overview.requiresSignIn || overview.renewalFailed ? Color.orange : Color.secondary)
                    if overview.requiresSignIn {
                        Text("This session has been revoked or can no longer be renewed. Automatic retries are paused until you sign in again.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if overview.renewalFailed {
                        Text("The last renewal did not finish. Try again later or reconnect this account.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 8) {
                        detail("Token expires", date: overview.expiresAt)
                        if let next = overview.nextAttempt { detail("Auto-renew", date: max(next, Date())) }
                    }
                    Divider()
                    usageSection
                    DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                        Text(model.sessionDetails(for: row)).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).padding(.top, 6)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(430, 160 + CGFloat(overview.usage?.windows.count ?? 0) * 70
                               + (overview.requiresSignIn || overview.renewalFailed ? 50 : 0)
                               + (usageError != nil ? 45 : 0) + (showTechnical ? 180 : 0)))
            HStack {
                if model.canRenew(row), let id = row.profileID {
                    Button("Renew Session") { Task { await model.renewSession(id: id) } }
                        .disabled(model.isWorking)
                }
                Button("Sign In Again…", action: signIn).disabled(model.isWorking)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 410)
    }

    private func detail(_ title: String, date: Date?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(date?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable")
        }.font(.callout)
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Usage limits").font(.subheadline.weight(.semibold))
                if let count = overview.usage?.availableResets {
                    Text("\(count) resets").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if row.profileID.map({ model.loadingUsage.contains($0) }) == true { ProgressView().controlSize(.small) }
                Button { Task { await model.loadUsage(for: row) } } label: {
                    Label(overview.usage == nil ? "Load" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isWorking || overview.requiresSignIn || row.profileID.map({ model.loadingUsage.contains($0) }) == true)
            }
            if let usage = overview.usage {
                if usage.windows.isEmpty {
                    Text("No usage windows were returned for this account.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(usage.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(window.bucket + " · " + window.durationLabel)
                            Spacer()
                            Text("\(Int(window.remainingPercent))% left").monospacedDigit()
                        }.font(.caption)
                        ProgressView(value: window.remainingPercent, total: 100)
                            .tint(window.remainingPercent < 10 ? .orange : .accentColor)
                        if let reset = window.resetsAt {
                            Text(reset > Date() ? "Resets " + reset.formatted(date: .abbreviated, time: .shortened) : "Reset time passed — refresh to update")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Saved reading · " + usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                }.font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Load remaining usage and reset times for this account.").font(.caption).foregroundStyle(.secondary)
            }
            if let usageError { Text(usageError).font(.caption).foregroundStyle(.orange) }
        }
    }
}
