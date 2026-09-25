import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import RelayCore

struct RemoteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var remote: RemoteModel
    @AppStorage("hide_emails") private var hideEmails = false
    private var rows: [ProfileRow] { model.rows(sortedBy: .created).filter { $0.profileID != nil } }
    private var phone: ProfileRow? { rows.first { $0.profileID == remote.selectedProfileID } }
    private var mac: ProfileRow? { rows.first { $0.isCurrent } }
    private func title(_ row: ProfileRow?) -> String {
        guard let row else { return "Choose account" }
        return hideEmails && row.title.contains("@") ? "Profile \(row.shortcutNumber.map(String.init) ?? String(row.id.prefix(4)))" : row.title
    }
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 12) {
                Button { remote.makePairing() } label: { device("iphone") }
                    .buttonStyle(.plain).disabled(phone == nil || remote.pairingBusy)
                    .help("Pair phone")
                Menu {
                    ForEach(rows) { row in
                        Button { if let id = row.profileID { remote.select(id) } } label: {
                            if row.profileID == remote.selectedProfileID { Label(title(row), systemImage: "checkmark") }
                            else { Text(title(row)) }
                        }
                    }
                    if rows.isEmpty { Text("Add an account first") }
                } label: { Text(title(phone)).lineLimit(1).truncationMode(.middle) }
                .menuStyle(.borderlessButton).help("Account used on your phone")
            }.frame(width: 130)
            Button { remote.toggleConnection() } label: {
                Image(systemName: remote.enabled ? "link" : "link.badge.plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(remote.connected && remote.runtimeReady ? Color.green : remote.enabled ? .orange : .secondary)
                    .frame(width: 30, height: 80)
            }.buttonStyle(.plain).disabled(phone == nil)
                .help("\(remote.status) · \(remote.enabled ? "Disconnect" : "Connect")")
                .accessibilityLabel("\(remote.status), \(remote.enabled ? "Disconnect" : "Connect")")
            VStack(spacing: 12) {
                Button { Task { await model.openRemoteDesktop() } } label: { device("laptopcomputer") }
                    .buttonStyle(.plain).help("Open ChatGPT")
                Menu {
                    ForEach(rows) { row in
                        Button { Task { await model.loadProfile(row) } } label: {
                            if row.isCurrent { Label(title(row), systemImage: "checkmark") }
                            else { Text(title(row)) }
                        }.disabled(row.isCurrent)
                    }
                } label: { Text(title(mac)).lineLimit(1).truncationMode(.middle) }
                .menuStyle(.borderlessButton).help("Account used on this Mac")
            }.frame(width: 130)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Remote", isPresented: Binding(get: { remote.error != nil }, set: { if !$0 { remote.error = nil } })) {
            Button("OK") { remote.error = nil }
        } message: { Text(remote.error ?? "") }
    }
    @ViewBuilder private func device(_ symbol: String) -> some View {
        let image = Image(systemName: symbol).font(.system(size: 35, weight: .light)).frame(width: 110, height: 80)
        if #available(macOS 26, *) { image.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20)) }
        else { image.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)) }
    }
}

@MainActor final class RemotePairingWindow: NSWindowController, NSWindowDelegate {
    private weak var model: RemoteModel?
    init(model: RemoteModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 216, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair Phone"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true; window.isRestorable = false; window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: RemotePairingView(model: model))
        content.sizingOptions = []
        if #available(macOS 14, *) { content.safeAreaRegions = [] }
        window.contentView = content
        let size = NSSize(width: 216, height: 200)
        window.setContentSize(size); window.contentMinSize = size; window.contentMaxSize = size
        super.init(window: window)
        window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { model?.cancelPairing() }
}

private struct RemotePairingView: View {
    @ObservedObject var model: RemoteModel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(model.pairing == nil ? Color(nsColor: .controlBackgroundColor) : .white)
            if let pairing = model.pairing, let image = qr(pairing.url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 176, height: 176)
                    .accessibilityLabel("Scan to pair ChatGPT Remote")
            } else if model.pairingBusy {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 12) {
                    Text(model.pairingError ?? "Code expired").font(.caption).multilineTextAlignment(.center)
                    Button("Try again") { model.makePairing() }
                }.padding(16)
            }
        }
        .frame(width: 196, height: 196)
        .padding(.horizontal, 10).padding(.top, -6).padding(.bottom, 10)
        .frame(width: 216, height: 200)
        .onExitCommand { model.cancelPairing() }
    }
    private func qr(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: output.extent.size)
    }
}
