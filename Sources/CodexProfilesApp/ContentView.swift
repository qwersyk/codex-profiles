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
                .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isWorking { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.startBrowserLoginProfile() }
                } label: {
                    Label("Sign In New Profile", systemImage: "person.crop.circle.badge.plus")
                }
                .help("Add account with browser sign-in (⇧⌘N)")
                Button {
                    Task { await addCurrentProfile() }
                } label: {
                    Label("Save Current Profile", systemImage: "tray.and.arrow.down")
                }
                .disabled(!model.currentProfile.isAvailable)
                .help("Save current profile (⌘S)")
                Button {
                    Task { await model.importProfileFromPanel() }
                } label: {
                    Label("Import Profiles", systemImage: "square.and.arrow.down")
                }
                .help("Import profiles or backup (⌘I)")
                Button {
                    Task { await model.logoutCodex() }
                } label: {
                    Label("Sign Out Locally", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(!model.currentProfile.isAvailable)
                .help("Sign out locally, preserving the saved session")
            }
        }
        .disabled(model.isWorking)
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
    @State private var confirmDelete = false
    @State private var showProfileActions = false
    let renameAction: () -> Void
    let loadAction: () -> Void
    let deleteAction: () -> Void
    let exportAction: () -> Void
    let detailsAction: () -> Void
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
            } else {
                HStack(spacing: 6) {
                    Button {
                        showProfileActions = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Profile actions")
                    .popover(isPresented: $showProfileActions, arrowEdge: .bottom) {
                        ProfileActionsPopover(
                            edit: { performProfileAction(renameAction) },
                            export: { performProfileAction(exportAction) },
                            details: { performProfileAction(detailsAction) },
                            signIn: { performProfileAction(signInAction) },
                            delete: { performProfileAction { confirmDelete = true } }
                        )
                    }
                    IconPill(symbol: row.isCurrent ? "checkmark" : "arrow.left.arrow.right", action: loadAction,
                             help: row.isCurrent ? "Current profile" : "Switch to this profile")
                        .disabled(row.isCurrent)
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
        )
    }

    private var background: Color {
        if row.isCurrent {
            return Color.accentColor.opacity(row.isUnsavedCurrent ? 0.05 : 0.09)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private func performProfileAction(_ action: @escaping () -> Void) {
        showProfileActions = false
        DispatchQueue.main.async { action() }
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

private struct ProfileActionsPopover: View {
    let edit: () -> Void
    let export: () -> Void
    let details: () -> Void
    let signIn: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            action("Edit Profile", symbol: "pencil", action: edit)
            action("Export Profile", symbol: "square.and.arrow.up", action: export)
            action("Session Details…", symbol: "info.circle", action: details)
            action("Sign In Again…", symbol: "arrow.triangle.2.circlepath", action: signIn)
            Divider().padding(.vertical, 4)
            action("Delete Profile", symbol: "trash", role: .destructive, action: delete)
        }
        .padding(8)
        .frame(width: 220)
    }

    private func action(
        _ title: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct SessionDetailsView: View {
    @ObservedObject var model: AppModel
    let row: ProfileRow
    let close: () -> Void
    let signIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Details").font(.headline)
            Text(model.sessionDetails(for: row)).font(.callout).textSelection(.enabled)
            if model.canRenew(row), let id = row.profileID {
                HStack {
                    Button("Renew Session") { Task { await model.renewSession(id: id) } }
                        .disabled(model.isWorking)
                    if model.isWorking { ProgressView().controlSize(.small) }
                }
            }
            HStack {
                Button("Sign In Again…", action: signIn)
                    .disabled(model.isWorking)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 370)
    }
}
