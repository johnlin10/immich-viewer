#if os(iOS)
import SwiftUI

/// iPhone and iPad: browsing only for now. Shares the server list, keys, sync and caches with the Mac app's code.
@main
struct ImmichViewerPhoneApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            PhoneRoot().environment(library)
        }
    }
}

/// Tabs on iPhone; on iPad they can become a sidebar.
struct PhoneRoot: View {
    @Environment(Library.self) private var library

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
                    Tab("People", systemImage: "person.crop.circle") {
                        NavigationStack { PeopleGrid().collectionDestinations() }
                    }
                    Tab("Albums", systemImage: "rectangle.stack") {
                        NavigationStack { AlbumGrid().collectionDestinations() }
                    }
                    Tab("Tags", systemImage: "tag") {
                        NavigationStack { TagList().collectionDestinations() }
                    }
                    Tab("Servers", systemImage: "server.rack") {
                        NavigationStack { PhoneServers() }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.onScrollDown)
                .id(library.serverURL) // another server: every tab starts over
            }
        }
        .task { await library.launch() }
    }
}

extension View {
    /// A person, album or tag opens its photos.
    func collectionDestinations() -> some View {
        navigationDestination(for: Person.self) { CollectionTimeline(context: .person($0.id), fallbackTitle: $0.name) }
            .navigationDestination(for: Album.self) { CollectionTimeline(context: .album($0.id), fallbackTitle: $0.albumName) }
            .navigationDestination(for: Tag.self) { CollectionTimeline(context: .tag($0.id), fallbackTitle: $0.value) }
    }
}
#endif
