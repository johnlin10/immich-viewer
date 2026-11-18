#if os(macOS)
import AppKit
import Sparkle
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    let updater: SPUUpdater
    @Environment(Library.self) private var library
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(updater: updater) }
            Tab("Video", systemImage: "play.rectangle", value: "video") { VideoSettings() }
            Tab("Storage", systemImage: "internaldrive", value: "storage") { StorageSettings() }
            Tab("Connection", systemImage: "network", value: "connection") { ServerList().padding(20) }
            Tab("Server", systemImage: "server.rack", value: "server") { ServerSettings(server: library.serverURL).id(library.serverURL) }
        }
        .frame(width: 460)
    }
}

/// "system", "light" or "dark", for the whole app.
func applyAppearance(_ value: String) {
    NSApp.appearance = switch value {
    case "light": NSAppearance(named: .aqua)
    case "dark": NSAppearance(named: .darkAqua)
    default: nil
    }
}

private struct GeneralSettings: View {
    let updater: SPUUpdater
    // Sparkle keeps these in its own preferences; copied here so the switches redraw
    @State private var checkUpdates = false
    @State private var installUpdates = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("gridSpacing") private var spacing = 1.0
    @AppStorage("cornerRadius") private var radius = 0.0
    @AppStorage("videoBadge") private var badge = true
    @AppStorage("fitWholePhoto") private var fit = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { applyAppearance(appearance) }

            SwiftUI.Section("Photo Grid") {
                LabeledContent("Spacing") {
                    Slider(value: $spacing, in: 0...8, step: 1) { EmptyView() } minimumValueLabel: { Text(verbatim: "0") } maximumValueLabel: { Text(verbatim: "8") }
                }
                LabeledContent("Corner Radius") {
                    Slider(value: $radius, in: 0...12, step: 1) { EmptyView() } minimumValueLabel: { Text(verbatim: "0") } maximumValueLabel: { Text(verbatim: "12") }
                }
                Toggle("Show Whole Photos", isOn: $fit)
                Toggle("Mark Videos (▶)", isOn: $badge)
            }

            SwiftUI.Section("Updates") {
                Toggle("Check for Updates Automatically", isOn: $checkUpdates)
                    .onChange(of: checkUpdates) { updater.automaticallyChecksForUpdates = checkUpdates }
                Toggle("Download and Install Updates Automatically", isOn: $installUpdates)
                    .onChange(of: installUpdates) { updater.automaticallyDownloadsUpdates = installUpdates }
                    .disabled(!checkUpdates)
                LabeledContent("Version") {
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            checkUpdates = updater.automaticallyChecksForUpdates
            installUpdates = updater.automaticallyDownloadsUpdates
        }
    }
}

private struct VideoSettings: View {
    @AppStorage("videoAutoplay") private var autoplay = true
    @AppStorage("videoMuted") private var muted = false
    @AppStorage("videoLoop") private var loop = false

    var body: some View {
        Form {
            Toggle("Play Automatically", isOn: $autoplay)
            Toggle("Start Muted", isOn: $muted)
            Toggle("Loop", isOn: $loop)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StorageSettings: View {
    @Environment(Library.self) private var library
    @State private var thumbs: Int?
    @State private var faces: Int?
    @State private var confirming = false

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Thumbnails", value: size(thumbs))
                LabeledContent("Faces", value: size(faces))
            } footer: {
                Text("Thumbnails are kept on this Mac, so scrolling doesn’t wait on the server. After clearing, photos download again when they are shown; Refresh (⌘R) gets them all back at once.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.thumbs.dir]) }
                Spacer()
                Button("Clear Cache…", role: .destructive) { confirming = true }
                    .disabled(library.syncing)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await measure() }
        .confirmationDialog("Clear all cached thumbnails?", isPresented: $confirming) {
            Button("Clear", role: .destructive) {
                library.thumbs.clear()
                library.faces.clear()
                Task { await measure() }
            }
        } message: {
            Text("Photos on the server are not affected.")
        }
    }

    private func size(_ bytes: Int?) -> String { bytes.map { $0.formatted(.byteCount(style: .file)) } ?? String(localized: "Calculating…") }

    private func measure() async {
        let stores = (library.thumbs, library.faces)
        (thumbs, faces) = await Task.detached { (stores.0.diskSize(), stores.1.diskSize()) }.value
    }
}

/// Server address and API key. Connect tries them before keeping the key.
/// Settings > Connection: every server connected to, the current one checked. + adds one, − removes, double-click or Use switches.
private struct ServerList: View {
    @Environment(Library.self) private var library
    @State private var selection: String?
    @State private var sheet: ServerSheet?
    @State private var removing: String?

    enum ServerSheet: Identifiable {
        case add, key(String)
        var id: String { if case .key(let server) = self { server } else { "" } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                List(library.servers, id: \.self, selection: $selection) { server in
                    HStack {
                        Image(systemName: "checkmark").opacity(server == library.serverURL ? 1 : 0)
                        Text(verbatim: server)
                        Spacer()
                        if server == library.serverURL { Text("Current").foregroundStyle(.secondary) }
                    }
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { servers in
                    if let server = servers.first { Task { await library.switchTo(server) } }
                }
                .frame(height: 150)
                Divider()
                HStack(spacing: 0) {
                    Button { sheet = .add } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add Server")
                    Divider().frame(height: 16)
                    Button { removing = selection } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .help("Remove Server")
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(2)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Text("Each server keeps its own API key, list and thumbnails. Double-click one to switch to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Change Key…") { if let selection { sheet = .key(selection) } }
                    .disabled(selection == nil)
                Button("Use") { if let selection { Task { await library.switchTo(selection) } } }
                    .disabled(selection == nil || selection == library.serverURL)
            }
        }
        .onAppear { selection = library.servers.contains(library.serverURL) ? library.serverURL : library.servers.first }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add: ConnectionForm(address: "", cancel: { self.sheet = nil }).padding(20).frame(width: 440)
            case .key(let server): ConnectionForm(address: server, cancel: { self.sheet = nil }).padding(20).frame(width: 440)
            }
        }
        .confirmationDialog(Text("Remove \(removing ?? "")?"), isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } }) {
            Button("Remove", role: .destructive) {
                if let removing {
                    selection = nil
                    Task { await library.remove(removing) }
                }
            }
        } message: {
            Text("Its API key, list and thumbnails are deleted from this Mac. Photos on the server are not affected.")
        }
    }
}

/// Address and API key. The whole window before the first connection; a sheet for adding a server or changing a key.
struct ConnectionForm: View {
    @Environment(Library.self) private var library
    /// nil: the current address (first connection). "": a new server. Else changing that server's key: the address stays.
    var address: String?
    /// Shows Cancel, and closes the sheet once connected.
    var cancel: (() -> Void)?
    @State private var server = ""
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?
    @State private var connected = false

    private var changingKey: Bool { !(address ?? "").isEmpty }

    var body: some View {
        Form {
            TextField("Server URL", text: $server, prompt: Text(verbatim: "http://localhost:2283"))
                .disabled(changingKey)
            // String(localized:) so the example addresses stay plain text instead of becoming links
            if !changingKey {
                Text(String(localized: "On this Mac: http://localhost:2283. On another computer in your network: its address and port, for example http://192.168.1.20:2283 or http://nas.local:2283. From outside your network: the https address of your reverse proxy, or the server’s Tailscale address."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("API Key", text: $key)
            Text("In the Immich web UI, open Account Settings > API Keys and create a new key with asset.read, asset.view, person.read and album.read. To copy or drag out originals, also add asset.download (without it, the large preview is used). The key is kept in the keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                } else if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                if let cancel { Button("Cancel", action: cancel).keyboardShortcut(.cancelAction) }
                Button {
                    checking = true
                    error = nil
                    connected = false
                    Task {
                        error = await library.connect(server: server, key: key, switching: !changingKey)
                        connected = error == nil
                        checking = false
                        if connected { cancel?() }
                    }
                } label: {
                    changingKey ? Text("Save") : Text("Connect")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty || ImmichAPI.address(server) == nil || checking)
            }
        }
        .onAppear { server = address ?? library.serverURL }
    }
}

/// Commands that start and stop the server, for the Server menu and for launch and quit.
private struct ServerSettings: View {
    @Environment(Library.self) private var library
    let server: String
    @AppStorage private var start: String
    @AppStorage private var stop: String
    @AppStorage private var startAtLaunch: Bool
    @AppStorage private var stopAtQuit: Bool

    /// The current server's commands; each server has its own.
    init(server: String) {
        self.server = server
        _start = AppStorage(wrappedValue: "", Library.setting("serverStart", server))
        _stop = AppStorage(wrappedValue: "", Library.setting("serverStop", server))
        _startAtLaunch = AppStorage(wrappedValue: false, Library.setting("serverStartAtLaunch", server))
        _stopAtQuit = AppStorage(wrappedValue: false, Library.setting("serverStopAtQuit", server))
    }

    /// Spaces alone aren't a command.
    private var noStart: Bool { start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var noStop: Bool { stop.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Start", text: $start)
                    .font(.body.monospaced())
                TextField("Stop", text: $stop)
                    .font(.body.monospaced())
            } header: {
                Text("Commands for \(server)")
            } footer: {
                Text("Commands run in zsh, as in Terminal. For a server on another computer, run them over SSH with key login, for example: ssh nas 'cd immich-app && docker compose up -d'")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SwiftUI.Section {
                Toggle("Start Automatically", isOn: $startAtLaunch)
                    .disabled(noStart)
                Toggle("Stop When Quitting", isOn: $stopAtQuit)
                    .disabled(noStop)
            } footer: {
                Text("Starts the server when Immich Viewer opens or switches to it, if it isn’t running. Stops it at quit only if Immich Viewer started it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if library.serverBusy {
                    ProgressView().controlSize(.small)
                    Text(library.status).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start Now") { Task { await library.startServer() } }
                    .disabled(noStart || library.serverBusy)
                Button("Stop Now") { Task { await library.stopServer() } }
                    .disabled(noStop || library.serverBusy)
            }
            if let error = library.serverError {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
