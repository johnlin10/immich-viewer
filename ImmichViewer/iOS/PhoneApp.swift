#if os(iOS)
import SwiftUI

/// iPhone and iPad. Shares the server list, keys, sync and caches with the Mac app's code.
@main
struct ImmichViewerPhoneApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            PhoneRoot().environment(library)
                .statusBarHidden(Immersion.shared.on)
                .animation(.easeInOut(duration: 0.25), value: Immersion.shared.on)
        }
    }
}

/// The open photo hid its bars: the status bar goes too. Set here, at the root, since the window's root controller
/// doesn't ask the presented photo page.
@Observable final class Immersion {
    static let shared = Immersion()
    var on = false
}

/// Tabs on iPhone; on iPad they can become a sidebar.
struct PhoneRoot: View {
    @Environment(Library.self) private var library
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var settingsShown = false

    var body: some View {
        Group {
            if library.api == nil {
                NavigationStack { PhoneConnectForm() }
            } else {
                TabView {
                    Tab("Library", systemImage: "photo.on.rectangle") {
                        NavigationStack {
                            TimelineBrowser(title: String(localized: "Library"), subtitle: library.status, assets: library.assets,
                                            revision: library.revision, context: .library)
                                .collectionDestinations()
                        }
                    }
                    // people, albums, tags and the utilities on one page, like Photos
                    Tab("Collections", systemImage: "square.stack") {
                        NavigationStack { CollectionsPage { settingsShown = true }.collectionDestinations() }
                    }
                    if sizeClass == .regular { // iPad: the albums and utilities in the sidebar too
                        TabSection("Albums") {
                            Tab("All Albums", systemImage: "rectangle.stack") {
                                NavigationStack { AlbumGrid().collectionDestinations() }
                            }
                            ForEach(library.albums) { album in
                                Tab(album.albumName, systemImage: "rectangle.stack") {
                                    NavigationStack {
                                        CollectionTimeline(context: .album(album.id), fallbackTitle: album.albumName).collectionDestinations()
                                    }
                                }
                            }
                        }
                        .tabPlacement(.sidebarOnly)
                        TabSection("Utilities") {
                            Tab("Archive", systemImage: "archivebox") {
                                NavigationStack { CollectionTimeline(context: .archive, fallbackTitle: String(localized: "Archive")) }
                            }
                            Tab("Trash", systemImage: "trash") {
                                NavigationStack { CollectionTimeline(context: .trash, fallbackTitle: String(localized: "Trash")) }
                            }
                        }
                        .tabPlacement(.sidebarOnly)
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.onScrollDown)
                .id(library.serverURL) // another server: every tab starts over
            }
        }
        .sheet(isPresented: $settingsShown) { // from Collections' top bar; out here: switching servers in it rebuilds the tabs
            NavigationStack {
                PhoneSettings()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsShown = false } } }
            }
        }
        .overlay { TransferPanel() }
        .alert("Couldn’t Make the Change", isPresented: Binding { library.editError != nil } set: { if !$0 { library.editError = nil } }) {
            Button("OK") {}
        } message: {
            Text(library.editError ?? "")
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .task { await library.launch() }
    }
}

#endif
