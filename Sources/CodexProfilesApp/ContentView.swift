import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

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
                        addAction: {
                            Task { await addCurrentProfile() }
                        }
                    )
                }

                if rows.isEmpty {
                    Image(systemName: "tray")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(10)
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
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Menu {
                    Picker("Sort", selection: selectedSortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
                .help("Sort")

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .help("Refresh")

                Button {
                    Task { await model.importProfileFromPanel() }
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .keyboardShortcut("i", modifiers: [.command])
                .help("Import Profile")

                Menu {
                    Button {
                        Task { await addCurrentProfile() }
                    } label: {
                        Label("Save Current Codex", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command])

                    Button {
                        Task { await model.startBrowserLoginProfile() }
                    } label: {
                        Label("Sign In New Profile", systemImage: "globe")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create Profile")

                Menu {
                    Button {
                        Task { await model.importArchiveFromPanel() }
                    } label: {
                        Label("Import Backup", systemImage: "square.and.arrow.down.on.square")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])

                    Button {
                        Task { await model.exportAllProfiles() }
                    } label: {
                        Label("Export All", systemImage: "square.and.arrow.up.on.square")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Backup")

                Button {
                    Task { await model.logoutCodex() }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Logout")
            }
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
        model.rows(sortedBy: selectedSortOrder.wrappedValue)
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
    let renameAction: () -> Void
    let loadAction: () -> Void
    let deleteAction: () -> Void
    let exportAction: () -> Void
    let addAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            avatarCircle(
                symbol: row.isUnsavedCurrent ? "person.crop.circle.badge.plus" : (row.avatarSymbol ?? AvatarOption.person.rawValue),
                tint: row.isUnsavedCurrent ? .secondary : avatarTint(row.avatarColorToken)
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if !row.isUnsavedCurrent && !showsSecondaryEmail {
                        editButton
                    }
                }

                HStack(spacing: 8) {
                    if let email = row.email, showsSecondaryEmail {
                        Text(email)
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
                    IconPill(symbol: "trash", action: deleteAction, help: "Delete Profile")
                    IconPill(symbol: "square.and.arrow.up", action: exportAction, help: "Export Profile")
                    IconPill(symbol: "arrow.down.circle", action: loadAction, help: "Load Profile")
                }
            }
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

                Button(action: cancelAction) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .keyboardShortcut(.cancelAction)

                Button(action: confirmAction) {
                    Image(systemName: "checkmark")
                        .frame(width: 28, height: 28)
                }
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

                Button(action: cancelAction) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
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
