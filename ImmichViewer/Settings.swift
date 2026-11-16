import AppKit
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Video", systemImage: "play.rectangle") { VideoSettings() }
            Tab("Storage", systemImage: "internaldrive") { StorageSettings() }
            Tab("Connection", systemImage: "network") { ConnectionForm().padding(20) }
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

/// Server address and API key.
struct ConnectionForm: View {
    @Environment(Library.self) private var library
    @State private var server = ""
    @State private var key = ""

    var body: some View {
        Form {
            TextField("Server URL", text: $server)
            SecureField("API Key", text: $key)
            Text("In the Immich web UI, open Account Settings > API Keys and create a new key with asset.read, asset.view, person.read and album.read. To copy or drag out originals, also add asset.download (without it, the large preview is used). The key is kept in the keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect") { library.connect(server: server, key: key) }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty || URL(string: server) == nil)
        }
        .onAppear { server = library.serverURL }
    }
}
