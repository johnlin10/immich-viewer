import AppKit
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Video", systemImage: "play.rectangle", value: "video") { VideoSettings() }
            Tab("Storage", systemImage: "internaldrive", value: "storage") { StorageSettings() }
            Tab("Connection", systemImage: "network", value: "connection") { ConnectionForm().padding(20) }
            Tab("Server", systemImage: "server.rack", value: "server") { ServerSettings() }
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
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("gridSpacing") private var spacing = 1.0
    @AppStorage("cornerRadius") private var radius = 0.0
    @AppStorage("videoBadge") private var badge = true
    @AppStorage("newestFirst") private var newestFirst = true
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
                Picker("Sort Order", selection: $newestFirst) {
                    Text("Newest First").tag(true)
                    Text("Oldest First").tag(false)
                }
                LabeledContent("Spacing") {
                    Slider(value: $spacing, in: 0...8, step: 1) { EmptyView() } minimumValueLabel: { Text(verbatim: "0") } maximumValueLabel: { Text(verbatim: "8") }
                }
                LabeledContent("Corner Radius") {
                    Slider(value: $radius, in: 0...12, step: 1) { EmptyView() } minimumValueLabel: { Text(verbatim: "0") } maximumValueLabel: { Text(verbatim: "12") }
                }
                Toggle("Show Whole Photos", isOn: $fit)
                Toggle("Mark Videos (▶)", isOn: $badge)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
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
struct ConnectionForm: View {
    @Environment(Library.self) private var library
    @State private var server = ""
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?
    @State private var connected = false

    var body: some View {
        Form {
            TextField("Server URL", text: $server, prompt: Text(verbatim: "http://localhost:2283"))
            // String(localized:) so the example addresses stay plain text instead of becoming links
            Text(String(localized: "On this Mac: http://localhost:2283. On another computer in your network: its address and port, for example http://192.168.1.20:2283 or http://nas.local:2283. From outside your network: the https address of your reverse proxy, or the server’s Tailscale address."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Button("Connect") {
                    checking = true
                    error = nil
                    connected = false
                    Task {
                        error = await library.connect(server: server, key: key)
                        connected = error == nil
                        checking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty || ImmichAPI.address(server) == nil || checking)
            }
        }
        .onAppear { server = library.serverURL }
    }
}

/// Commands that start and stop the server, for the Server menu and for launch and quit.
private struct ServerSettings: View {
    @Environment(Library.self) private var library
    @AppStorage("serverStart") private var start = ""
    @AppStorage("serverStop") private var stop = ""
    @AppStorage("serverStartAtLaunch") private var startAtLaunch = false
    @AppStorage("serverStopAtQuit") private var stopAtQuit = false

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Start", text: $start, prompt: Text(verbatim: "cd ~/immich-app && docker compose up -d"))
                    .font(.body.monospaced())
                TextField("Stop", text: $stop, prompt: Text(verbatim: "cd ~/immich-app && docker compose stop"))
                    .font(.body.monospaced())
            } footer: {
                Text("Commands run in zsh, as in Terminal. For a server on another computer, run them over SSH with key login, for example: ssh nas 'cd immich-app && docker compose up -d'")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SwiftUI.Section {
                Toggle("Start the server when Immich Viewer opens, if it isn’t running", isOn: $startAtLaunch)
                    .disabled(start.isEmpty)
                Toggle("Stop the server when Immich Viewer quits, if Immich Viewer started it", isOn: $stopAtQuit)
                    .disabled(stop.isEmpty)
            }
            HStack {
                if library.serverBusy {
                    ProgressView().controlSize(.small)
                    Text(library.status).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start Now") { Task { await library.startServer() } }
                    .disabled(start.isEmpty || library.serverBusy)
                Button("Stop Now") { Task { await library.stopServer() } }
                    .disabled(stop.isEmpty || library.serverBusy)
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
