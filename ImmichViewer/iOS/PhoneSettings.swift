#if os(iOS)
import SwiftUI

/// The Settings tab: the servers (tap one to switch, swipe to change its key or remove it), how the app looks,
/// video playback, the thumbnail cache and the version.
struct PhoneSettings: View {
    @Environment(Library.self) private var library
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("videoAutoplay") private var autoplay = true
    @AppStorage("videoMuted") private var muted = false
    @AppStorage("videoLoop") private var loop = false
    @State private var adding = false
    @State private var changingKey: String?
    @State private var removing: String?
    @State private var thumbs: Int?
    @State private var faces: Int?
    @State private var clearing = false

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(library.servers, id: \.self) { server in
                    Button {
                        Task { await library.switchTo(server) }
                    } label: {
                        HStack {
                            Text(verbatim: server)
                            Spacer()
                            if server == library.serverURL { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { removing = server }
                        Button("Change Key", systemImage: "key") { changingKey = server }
                    }
                }
                Button("Add Server…", systemImage: "plus") { adding = true }
            } header: {
                Text("Servers")
            } footer: {
                Text("Tap a server to switch to it. Swipe left on one to change its API key or remove it.")
            }

            SwiftUI.Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear) // the control is its own capsule; no card around it
                .listRowInsets(EdgeInsets())
            }

            SwiftUI.Section("Video") {
                Toggle("Play Automatically", isOn: $autoplay)
                Toggle("Start Muted", isOn: $muted)
                Toggle("Loop", isOn: $loop)
            }

            SwiftUI.Section {
                LabeledContent("Thumbnails", value: size(thumbs))
                LabeledContent("Faces", value: size(faces))
                Button("Clear Cache…", role: .destructive) { clearing = true }
                    .disabled(library.syncing)
            } header: {
                Text("Storage")
            } footer: {
                Text("Thumbnails are kept on this device, so scrolling doesn’t wait on the server. After clearing, photos download again when they are shown.")
            }

            SwiftUI.Section {
                LabeledContent("Version") {
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
        }
        .pageBar()
        .navigationTitle("Settings")
        .task { await measure() }
        .sheet(isPresented: $adding) {
            NavigationStack { PhoneConnectForm(address: "") { adding = false } }
        }
        .sheet(item: Binding(get: { changingKey.map(Identified.init) }, set: { changingKey = $0?.id })) { item in
            NavigationStack { PhoneConnectForm(address: item.id) { changingKey = nil } }
        }
        .confirmationDialog(Text("Remove \(removing ?? "")?"), isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { Task { await library.remove(removing) } }
            }
        } message: {
            Text("Its API key, list and thumbnails are deleted from this device. Photos on the server are not affected.")
        }
        .confirmationDialog("Clear all cached thumbnails?", isPresented: $clearing, titleVisibility: .visible) {
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

    private struct Identified: Identifiable { let id: String }
}

/// Address and API key. nil: the first connection. "": a new server. Else changing that server's key.
struct PhoneConnectForm: View {
    @Environment(Library.self) private var library
    var address: String?
    /// Shows Cancel, and is called once connected.
    var done: (() -> Void)?
    @State private var server = ""
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?

    private var changingKey: Bool { !(address ?? "").isEmpty }

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Server URL", text: $server, prompt: Text(verbatim: "https://photos.example.com"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(changingKey)
                SecureField("API Key", text: $key)
            } footer: {
                Text("In the Immich web UI, open Account Settings > API Keys and create a key with asset.read, asset.view, person.read and album.read. To make changes and share originals too, give it all permissions. The key is kept in the keychain.")
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle(changingKey ? "Change Key" : "Connect to Immich")
        .toolbar {
            if let done {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            }
            ToolbarItem(placement: .confirmationAction) {
                if checking {
                    ProgressView()
                } else {
                    Button {
                        checking = true
                        error = nil
                        Task {
                            error = await library.connect(server: server, key: key, switching: !changingKey)
                            checking = false
                            if error == nil { done?() }
                        }
                    } label: {
                        changingKey ? Text("Save") : Text("Connect")
                    }
                    .disabled(key.isEmpty || ImmichAPI.address(server) == nil)
                }
            }
        }
        .onAppear { server = address ?? (library.servers.isEmpty ? "" : library.serverURL) }
    }
}
#endif
