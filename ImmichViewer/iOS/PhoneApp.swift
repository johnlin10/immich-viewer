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

/// Beside the collapsed tab bar, like the Years / Months / All Photos in Photos: how the photos are grouped.
private struct GroupingAccessory: View {
    @AppStorage("grouping") private var grouping = Grouping.day

    var body: some View {
        Picker("Group By", selection: $grouping) {
            ForEach(Grouping.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    struct Shown: ViewModifier {
        let enabled: Bool

        func body(content: Content) -> some View {
            if #available(iOS 26.1, *) {
                content.tabViewBottomAccessory(isEnabled: enabled) { GroupingAccessory() }
            } else { // ponytail: no picker on 26.0, which can't turn the accessory off
                content
            }
        }
    }
}

/// Library scrolled down from the top, so the grouping picker shows: beside the collapsed tab bar, or above it once expanded.
/// ponytail: the system has no "tab bar collapsed" to read, and how far up it takes to expand is its own call, so only the top turns it off
@Observable final class GroupingPicker {
    static let shared = GroupingPicker()
    var shown = false
}

/// Tabs on iPhone; on iPad they can become a sidebar.
struct PhoneRoot: View {
    @Environment(Library.self) private var library
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// The app was in the background, so the live connection is down and events were missed.
    @State private var wasBackground = false
    @State private var settingsShown = false
    /// The search field (in the tab bar's place on the Search tab, like Photos), and what Return last searched for.
    @State private var searchText = ""
    @State private var searchQuery = ""

    private var searchTab: some View {
        NavigationStack {
            SearchResults(query: searchQuery)
                .collectionDestinations()
                .searchable(text: $searchText, prompt: Text("Search your library")) // here, not on the tabs: only this page has the field
                .searchPresentationToolbarBehavior(.avoidHidingContent) // the toolbar buttons stay while searching
                .onSubmit(of: .search) { searchQuery = searchText.trimmingCharacters(in: .whitespaces) }
                .onChange(of: searchText) { if searchText.isEmpty { searchQuery = "" } }
        }
    }

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
                    if sizeClass == .regular { // iPad: memories, the albums and utilities in the sidebar too
                        Tab("Memories", systemImage: "memories") {
                            NavigationStack { MemoryGrid().collectionDestinations() }
                        }
                        .tabPlacement(.sidebarOnly)
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
                    // last: on iPhone a round button apart from the tab bar, that turns into the field, like Photos
                    Tab(role: .search) { searchTab }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabViewSearchActivation(.searchTabSelection) // the Search tab opens with the field and keyboard up
                .tabBarMinimizeBehavior(.onScrollDown)
                // on iPhone, only once Library leaves the top: there the tabs stand alone, as in Photos
                .modifier(GroupingAccessory.Shown(enabled: sizeClass == .compact && GroupingPicker.shared.shown))
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
        .onChange(of: library.editError) { showEditError() }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .task { await library.launch() }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                wasBackground = true
                library.stopListening()
            } else if scenePhase == .active, wasBackground { // not the first activation: launch() did it
                wasBackground = false
                library.listen()
                Task { await library.refresh() }
            }
        }
    }

    /// Over whatever is on top (an open photo, its details, a sheet), which a SwiftUI alert here can't reach.
    private func showEditError() {
        guard let message = library.editError,
              var top = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController
        else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let alert = UIAlertController(title: String(localized: "Couldn’t Make the Change"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in library.editError = nil })
        top.present(alert, animated: true)
    }
}

#endif
