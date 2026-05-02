import SwiftUI

@main
struct CodexProfilesApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Codex Profiles") {
            ContentView(model: model)
                .task {
                    appDelegate.setOpenHandler { urls in
                        Task { await model.importFiles(urls) }
                    }
                }
        }
        .defaultSize(width: 520, height: 430)
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
