#if os(iOS)
import SwiftUI

/// The servers tab: tap one to switch, swipe to change its key or remove it, + to add one.
struct PhoneServers: View {
    @Environment(Library.self) private var library
    @State private var adding = false
    @State private var changingKey: String?
    @State private var removing: String?

    var body: some View {
        List {
            ForEach(library.servers, id: \.self) { server in
                Button {
                    Task { await library.switchTo(server) }
                } label: {
                    HStack {
                        Text(verbatim: server)
                        Spacer()
                        if server == library.serverURL { Image(systemName: "checkmark").foregroundStyle(.blue) }
                    }
                }
                .tint(.primary)
                .swipeActions {
                    Button("Remove", systemImage: "trash", role: .destructive) { removing = server }
                    Button("Change Key", systemImage: "key") { changingKey = server }
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            Button("Add Server", systemImage: "plus") { adding = true }
        }
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
                Text("In the Immich web UI, open Account Settings > API Keys and create a key with asset.read, asset.view, person.read and album.read. The key is kept in the keychain.")
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
