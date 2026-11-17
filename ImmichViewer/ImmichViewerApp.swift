import MapKit
import Sparkle
import SwiftUI

@main
struct ImmichViewerApp: App {
    @State private var library = Library()
    /// Sparkle: checks the feed in Info.plist (SUFeedURL) about once a day and installs signed updates.
    private let updates = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup {
            ContentView().environment(library)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates(nil) }
            }
            ViewCommands(library: library)
            ServerCommands(library: library)
        }
        Settings {
            SettingsView(updater: updates.updater).environment(library)
        }
    }
}

/// What the View menu can do to the grid in the front window.
struct BrowserActions {
    var viewerOpen: Bool
    var toTop: () -> Void
    var toBottom: () -> Void
    var askDate: () -> Void
}

extension FocusedValues {
    @Entry var browser: BrowserActions?
}

extension EnvironmentValues {
    /// Opens a person's page, for example from the info panel.
    @Entry var showPerson: (Person) -> Void = { _ in }
}

/// The View menu, after the toolbar items.
struct ViewCommands: Commands {
    let library: Library
    @FocusedValue(\.browser) private var browser
    @AppStorage("zoomLevel") private var level = 4
    @AppStorage("grouping") private var grouping = Grouping.day
    @AppStorage("fitWholePhoto") private var fit = false

    var body: some Commands {
        // only for a grid with no photo open over it
        let off = browser?.viewerOpen != false
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await library.refresh() } }
                .keyboardShortcut("r")
                .disabled(library.syncing || library.api == nil)
            Divider()
            Button("Zoom In") { level = min(level + 1, zoomLevels.count - 1) }
                .keyboardShortcut("=")
                .disabled(off || level >= zoomLevels.count - 1)
            Button("Zoom Out") { level = max(level - 1, 0) }
                .keyboardShortcut("-")
                .disabled(off || level <= 0)
            Divider()
            ForEach(Array(Grouping.allCases.enumerated()), id: \.element) { i, option in
                Toggle(isOn: Binding { grouping == option } set: { _ in grouping = option }) { Text(option.label) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            .disabled(off)
            Toggle("Show Whole Photos", isOn: $fit).disabled(off)
            Divider()
            Button("Go to Top") { browser?.toTop() }
                .keyboardShortcut(.upArrow)
                .disabled(off)
            Button("Go to Bottom") { browser?.toBottom() }
                .keyboardShortcut(.downArrow)
                .disabled(off)
            Button("Go to Date…") { browser?.askDate() }
                .keyboardShortcut("j")
                .disabled(off)
        }
    }
}

/// The Server menu: the start and stop commands from Settings > Server.
struct ServerCommands: Commands {
    let library: Library
    @AppStorage("serverStart") private var start = ""
    @AppStorage("serverStop") private var stop = ""
    @AppStorage("settingsTab") private var tab = "general"
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandMenu("Server") {
            Button("Start Server") { Task { await library.startServer() } }
                .disabled(start.isEmpty || library.serverBusy)
            Button("Stop Server") { Task { await library.stopServer() } }
                .disabled(stop.isEmpty || library.serverBusy)
            Divider()
            Button("Start and Stop Commands…") {
                tab = "server"
                openSettings()
            }
        }
    }
}

/// The sidebar's pages.
enum Page: Hashable {
    case library, people, albums
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var page: Page? = .library
    /// The person open on the People page.
    @State private var personPath: [Person] = []
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Group {
            if library.api == nil {
                ConnectionForm().padding(20).frame(width: 440)
            } else {
                NavigationSplitView {
                    List(selection: $page) {
                        Label("Library", systemImage: "photo.on.rectangle").tag(Page.library)
                        Label("People", systemImage: "person.crop.circle").tag(Page.people)
                        Label("Albums", systemImage: "rectangle.stack").tag(Page.albums)
                    }
                    .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 260)
                } detail: {
                    switch page ?? .library {
                    case .library:
                        TimelineBrowser(title: String(localized: "Library"), subtitle: library.status, assets: library.assets,
                                        revision: library.revision, context: .library)
                    case .people:
                        NavigationStack(path: $personPath) {
                            PeopleGrid().navigationDestination(for: Person.self) { person in
                                CollectionTimeline(context: .person(person.id), fallbackTitle: person.name)
                            }
                        }
                    case .albums:
                        NavigationStack {
                            AlbumGrid().navigationDestination(for: Album.self) { album in
                                CollectionTimeline(context: .album(album.id), fallbackTitle: album.albumName)
                            }
                        }
                    }
                }
                .environment(\.showPerson) { person in
                    page = .people
                    personPath = [person]
                }
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .alert("Couldn’t Make the Change", isPresented: Binding { library.editError != nil } set: { if !$0 { library.editError = nil } }) {
            Button("OK") {}
        } message: {
            Text(library.editError ?? "")
        }
        .task { await library.launch() }
        .onChange(of: appearance, initial: true) { applyAppearance(appearance) }
    }
}

/// A photo grid with its zoom and grouping controls, date capsule and single photo view.
/// Shows the whole library, or one person's or album's photos.
struct TimelineBrowser: View {
    @Environment(Library.self) private var library
    let title: String
    let subtitle: String
    let assets: [Asset]
    /// Changes whenever `assets` is replaced, so the grid regroups.
    let revision: Int
    let context: BrowserContext
    @AppStorage("zoomLevel") private var level = 4
    @AppStorage("grouping") private var grouping = Grouping.day
    @AppStorage("fitWholePhoto") private var fit = false
    @AppStorage("gridSpacing") private var spacing = 1.0
    @AppStorage("cornerRadius") private var radius = 0.0
    @AppStorage("videoBadge") private var badge = true
    @AppStorage("newestFirst") private var newestFirst = true
    @State private var grid = GridData()
    @State private var viewer: ViewerState?
    @State private var bridge = GridBridge()
    @State private var askingDate = false
    @State private var sheet: EditSheet?
    /// Photos waiting for Delete to be confirmed.
    @State private var trashing: [String]?
    @State private var deletingAlbum = false
    @Environment(\.undoManager) private var undo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let titleBar = geo.safeAreaInsets.top
            PhotoGrid(library: library, data: grid, level: min(max(level, 0), zoomLevels.count - 1),
                      showHeaders: grouping != .none,
                      style: GridStyle(fit: fit, spacing: spacing, radius: radius, badge: badge),
                      // the first row starts below the date capsule
                      insets: NSEdgeInsets(top: titleBar + 44, left: 0, bottom: 64, right: 0),
                      active: viewer == nil,
                      onZoom: { level = $0 }, onOpen: { viewer = ViewerState(index: $0, origin: $1, image: $2) },
                      onAction: { perform($0, $1) },
                      menu: { indices in
                          NSHostingMenu(rootView: PhotoMenu(library: library, count: indices.count,
                                                            allFavorite: indices.allSatisfy { grid.assets[$0].isFavorite == true },
                                                            context: context) { perform($0, indices) })
                      },
                      bridge: bridge)
                .ignoresSafeArea(edges: .vertical)
                .overlay(alignment: .top) { TitleBarBlur(height: titleBar) }
                .overlay(alignment: .topLeading) {
                    // the date of the top row, under the window buttons and title
                    DateCapsule(bridge: bridge, assets: grid.assets)
                        .padding(.leading, 12)
                        .padding(.top, 6)
                }
                .overlay(alignment: .trailing) {
                    Scrubber(bridge: bridge, assets: grid.assets, years: grid.years)
                        .padding(.top, titleBar + 8) // clear of the title bar and the ⋯ button
                        .padding(.bottom, 20)
                        .opacity(viewer == nil ? 1 : 0)
                }
                .overlay(alignment: .bottom) {
                    BottomBar(level: $level, grouping: $grouping)
                        .padding(.bottom, 14)
                        .disabled(viewer != nil)
                }
                .background {
                    // the ⋯ menu; also gives the window a toolbar, which puts the subtitle under the title.
                    // The photo viewer brings its own items, so this one comes and goes with it.
                    if viewer == nil {
                        Color.clear.toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Menu {
                                    Toggle("Show Whole Photos", isOn: $fit)
                                    collectionMenu
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuIndicator(.hidden)
                                .help("More")
                            }
                        }
                    }
                }
                .overlay {
                    if let viewer {
                        PhotoViewer(library: library, assets: grid.assets, revision: grid.id, context: context, topInset: titleBar,
                                    bridge: bridge, start: viewer, perform: perform) { self.viewer = nil }
                    }
                }
        }
        // the single photo view puts its own date in the middle of the title bar
        .navigationTitle(viewer == nil ? title : "")
        .navigationSubtitle(viewer != nil ? "" : bridge.chosen > 1 ? String(localized: "\(bridge.chosen) selected") : subtitle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: revision, initial: true) { regroup() }
        .onChange(of: grouping) { regroup() }
        .onChange(of: newestFirst) { regroup() }
        .focusedSceneValue(\.browser, BrowserActions(
            viewerOpen: viewer != nil,
            toTop: { bridge.jump(to: 0) },
            toBottom: { bridge.jump(to: grid.assets.count - 1) },
            askDate: { askingDate = true }))
        .sheet(isPresented: $askingDate) {
            JumpToDate(assets: grid.assets, current: bridge.top) { if let i = index(of: $0, in: grid.assets) { bridge.jump(to: i) } }
        }
        .editSheet($sheet, library: library, undo: undo)
        .alert(trashing?.count == 1 ? "Delete This Photo?" : "Delete \(trashing?.count ?? 0) Photos?",
               isPresented: Binding { trashing != nil } set: { if !$0 { trashing = nil } }) {
            Button("Delete", role: .destructive) {
                if let ids = trashing { Task { await library.trash(ids, undo: undo) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(library.trashEnabled
                 ? "They go to the server’s trash, which keeps them for 30 days unless the server is set otherwise. ⌘Z puts them back."
                 : "The server’s trash is turned off, so they are deleted for good.")
        }
        .alert("Delete This Album?", isPresented: $deletingAlbum) {
            Button("Delete", role: .destructive) {
                guard let album else { return }
                Task {
                    await library.delete(album)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos in it stay in your library.")
        }
    }

    private var album: Album? {
        guard case .album(let id) = context else { return nil }
        return library.albums.first { $0.id == id }
    }

    private var person: Person? {
        guard case .person(let id) = context else { return nil }
        return library.people.first { $0.id == id }
    }

    /// The ⋯ menu's part for an album or person page.
    @ViewBuilder private var collectionMenu: some View {
        if let album {
            Divider()
            Button("Edit Album…") { sheet = .editAlbum(album) }
            Button("Delete Album…") { deletingAlbum = true }
        }
        if let person {
            Divider()
            Button("Edit Person…") { sheet = .editPerson(person) }
            Button("Hide Person") {
                Task {
                    await library.update(person, hidden: true, was: person, undo: undo)
                    dismiss()
                }
            }
        }
    }

    /// Does `action` to photos `indices` (into `grid.assets`). `place`: where the photo is now, from the photo view.
    private func perform(_ action: PhotoAction, _ indices: [Int], place: CLLocationCoordinate2D? = nil) {
        let ids = indices.filter(grid.assets.indices.contains).map { grid.assets[$0].id }
        guard let first = indices.first, !ids.isEmpty else { return }
        switch action {
        case .favorite:
            let all = indices.allSatisfy { grid.assets[$0].isFavorite == true }
            Task { await library.favorite(ids, !all, undo: undo) }
        case .archive: Task { await library.archive(ids, true, undo: undo) }
        case .trash: trashing = ids
        case .add(let album): Task { await library.add(ids, to: album, undo: undo) }
        case .newAlbum: sheet = .newAlbum(ids)
        case .adjustDate: sheet = .date(ids, grid.assets[first].date)
        case .setLocation: sheet = .location(ids, place)
        case .removeFromAlbum:
            if case .album(let album) = context { Task { await library.remove(ids, from: album, undo: undo) } }
        case .makeCover:
            if var new = album {
                new.albumThumbnailAssetId = ids[0]
                let old = album!
                Task { await library.update(new, was: old, undo: undo) }
            }
        case .makeProfilePhoto:
            if case .person(let person) = context { Task { await library.setProfilePhoto(person, from: ids[0]) } }
        }
    }

    private func regroup() {
        let list = newestFirst ? assets : assets.reversed()
        grid = GridData(assets: list, sections: makeSections(list, by: grouping), years: yearStarts(list), id: grid.id + 1)
    }
}

/// Floating controls over the bottom of the grid, one glass capsule per job.
/// The chosen grouping sits on one tinted piece of glass that slides over to the next choice, like an iOS tab bar.
struct BottomBar: View {
    @Binding var level: Int
    @Binding var grouping: Grouping
    @Namespace private var glass
    /// The option the glass is on. Its own state, because a change to the stored setting doesn't carry the animation.
    @State private var selected = Grouping.day

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    // ⌘− and ⌘= live in the View menu
                    BarIcon("minus.magnifyingglass") { level -= 1 }
                        .disabled(level <= 0)
                        .help("Zoom Out (⌘−)")
                    BarIcon("plus.magnifyingglass") { level += 1 }
                        .disabled(level >= zoomLevels.count - 1)
                        .help("Zoom In (⌘+)")
                }
                .modifier(GlassCapsule())
                HStack(spacing: 0) {
                    ForEach(Grouping.allCases, id: \.self) { option in
                        Button { grouping = option } label: {
                            Text(option.label)
                                .padding(.horizontal, 14)
                                .frame(height: 28)
                                .foregroundStyle(selected == option ? .white : .primary)
                                .contentShape(Capsule())
                        }
                        .matchedGeometryEffect(id: option, in: glass) // where the glass goes for this option
                        .accessibilityAddTraits(selected == option ? .isSelected : [])
                    }
                }
                .background {
                    // one piece of glass that takes the chosen option's place, so a change slides it across
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                        .matchedGeometryEffect(id: selected, in: glass, isSource: false)
                }
                .modifier(GlassCapsule())
                .onChange(of: grouping, initial: true) { old, new in
                    // also for ⌘1–⌘3 in the View menu
                    withAnimation(old == new ? nil : .bouncy(duration: 0.4)) { selected = new }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// An icon button sized to fill a bar capsule.
struct BarIcon: View {
    let symbol: String
    let action: () -> Void

    init(_ symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.large)
                .frame(width: 36, height: 28)
                .contentShape(Capsule())
        }
    }
}

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View { content.padding(4).glassEffect(.regular, in: .capsule) }
}

/// Progressive blur behind the title bar: strongest at the top, gone at the title bar's bottom edge.
/// A material only blurs by a fixed amount, so several are stacked, each reaching a little less far down;
/// each one blurs what is already blurred under it, so the blur builds up toward the top.
struct TitleBarBlur: View {
    let height: CGFloat
    private let layers = 4

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(1...layers, id: \.self) { i in
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: height * Double(layers - i + 1) / Double(layers))
            }
            // light tint so the title stays readable over bright photos
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0.4), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: height, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

