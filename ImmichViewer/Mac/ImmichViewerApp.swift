#if os(macOS)
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
            ImportCommands(library: library)
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
    /// Uploads go into this album too.
    var album: String?
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

/// File > Import…: uploads files to the server, into the open album if there is one.
struct ImportCommands: Commands {
    let library: Library
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [.image, .movie]
                panel.prompt = String(localized: "Upload")
                guard panel.runModal() == .OK else { return }
                Task { await library.upload(panel.urls, album: browser?.album) }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(library.api == nil)
        }
    }
}

/// The Server menu: the current server's start and stop commands from Settings > Server, and switching servers.
struct ServerCommands: Commands {
    let library: Library
    @AppStorage("settingsTab") private var tab = "general"
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandMenu("Server") {
            StartStopItems(library: library, server: library.serverURL).id(library.serverURL)
            if library.servers.count > 1 {
                Divider()
                ForEach(library.servers, id: \.self) { server in
                    Toggle(isOn: Binding { server == library.serverURL } set: { _ in Task { await library.switchTo(server) } }) {
                        Text(verbatim: server)
                    }
                }
            }
            Divider()
            Button("Start and Stop Commands…") {
                tab = "server"
                openSettings()
            }
        }
    }
}

/// Start and Stop in the Server menu, for the current server's commands.
private struct StartStopItems: View {
    let library: Library
    @AppStorage private var start: String
    @AppStorage private var stop: String

    init(library: Library, server: String) {
        self.library = library
        _start = AppStorage(wrappedValue: "", Library.setting("serverStart", server))
        _stop = AppStorage(wrappedValue: "", Library.setting("serverStop", server))
    }

    /// Spaces alone aren't a command.
    private var noStart: Bool { start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var noStop: Bool { stop.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Button("Start Server") { Task { await library.startServer() } }
            .disabled(noStart || library.serverBusy)
        Button("Stop Server") { Task { await library.stopServer() } }
            .disabled(noStop || library.serverBusy)
    }
}

/// The sidebar's pages.
enum Page: Hashable {
    case library, people, albums, tags, archive, trash
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var page: Page? = .library
    /// What's open on top of each page; back returns to where you were.
    @State private var paths: [Page: NavigationPath] = [:]
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
                        Label("Tags", systemImage: "tag").tag(Page.tags)
                        Label("Archive", systemImage: "archivebox").tag(Page.archive)
                        Label("Trash", systemImage: "trash").tag(Page.trash)
                    }
                    .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 260)
                } detail: {
                    let current = page ?? .library
                    NavigationStack(path: Binding { paths[current] ?? NavigationPath() } set: { paths[current] = $0 }) {
                        root(current)
                            .navigationDestination(for: Person.self) {
                                CollectionTimeline(context: .person($0.id), fallbackTitle: $0.name)
                            }
                            .navigationDestination(for: Album.self) {
                                CollectionTimeline(context: .album($0.id), fallbackTitle: $0.albumName)
                            }
                            .navigationDestination(for: Tag.self) {
                                CollectionTimeline(context: .tag($0.id), fallbackTitle: $0.value)
                            }
                    }
                    .id(current) // each page its own stack
                    .environment(\.showPerson) { paths[current, default: NavigationPath()].append($0) }
                }
                .id(library.serverURL) // another server: every page starts over
            }
        }
        .onChange(of: library.serverURL) { paths = [:] }
        .frame(minWidth: 700, minHeight: 400)
        .overlay { TransferPanel() }
        .alert("Couldn’t Make the Change", isPresented: Binding { library.editError != nil } set: { if !$0 { library.editError = nil } }) {
            Button("OK") {}
        } message: {
            Text(library.editError ?? "")
        }
        .task { await library.launch() }
        .onChange(of: appearance, initial: true) { applyAppearance(appearance) }
    }

    @ViewBuilder private func root(_ page: Page) -> some View {
        switch page {
        case .library:
            TimelineBrowser(title: String(localized: "Library"), subtitle: library.status, assets: library.assets,
                            revision: library.revision, context: .library)
        case .people: PeopleGrid()
        case .albums: AlbumGrid()
        case .tags: TagList()
        case .archive: CollectionTimeline(context: .archive, fallbackTitle: String(localized: "Archive"))
        case .trash: CollectionTimeline(context: .trash, fallbackTitle: String(localized: "Trash"))
        }
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
    /// Not kept: every page opens showing everything.
    @State private var filter = PhotoFilter()
    @State private var viewer: ViewerState?
    @State private var bridge = GridBridge()
    @State private var askingDate = false
    @State private var editor = PhotoEditor()
    @Environment(\.undoManager) private var undo

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
                                FilterMenu(active: filter.isActive) { filter = PhotoFilter() } items: {
                                    Toggle(isOn: $filter.photos) { Label("Photos", systemImage: "photo") }
                                    Toggle(isOn: $filter.videos) { Label("Videos", systemImage: "video") }
                                    Toggle(isOn: $filter.live) { Label("Live Photos", systemImage: "livephoto") }
                                    Divider()
                                    Toggle(isOn: $filter.favorites) { Label("Favorites", systemImage: "heart") }
                                }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                SortMenu(selection: $newestFirst) {
                                    Label("Newest First", systemImage: "arrow.down").tag(true)
                                    Label("Oldest First", systemImage: "arrow.up").tag(false)
                                }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Menu {
                                    Toggle("Show Whole Photos", isOn: $fit)
                                    CollectionMenu(library: library, context: context, editor: editor, undo: undo)
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
                    if filter.isActive, grid.assets.isEmpty, !assets.isEmpty {
                        ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
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
        .navigationBarBackButtonHidden(viewer != nil) // ✕ closes the photo; back would leave the page too
        .navigationSubtitle(shownSubtitle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: revision, initial: true) { regroup() }
        .onChange(of: grouping) { regroup() }
        .onChange(of: newestFirst) { regroup() }
        .onChange(of: filter) { regroup() }
        .focusedSceneValue(\.browser, BrowserActions(
            viewerOpen: viewer != nil,
            toTop: { bridge.jump(to: 0) },
            toBottom: { bridge.jump(to: grid.assets.count - 1) },
            askDate: { askingDate = true },
            album: album?.id))
        .sheet(isPresented: $askingDate) {
            JumpToDate(assets: grid.assets, current: bridge.top) { if let i = index(of: $0, in: grid.assets) { bridge.jump(to: i) } }
        }
        .photoEditor(editor, library: library, undo: undo)
    }

    /// Nothing over an open photo; how many are chosen; else the page's subtitle, with how many a filter leaves.
    private var shownSubtitle: String {
        if viewer != nil { return "" }
        if bridge.chosen > 1 { return String(localized: "\(bridge.chosen) selected") }
        return countSubtitle(subtitle, shown: grid.assets.count, filtered: filter.isActive)
    }

    private var album: Album? {
        guard case .album(let id) = context else { return nil }
        return library.albums.first { $0.id == id }
    }

    /// Does `action` to photos `indices` (into `grid.assets`). `place`: where the photo is now, from the photo view.
    private func perform(_ action: PhotoAction, _ indices: [Int], place: CLLocationCoordinate2D? = nil) {
        editor.perform(action, on: indices.filter(grid.assets.indices.contains).map { grid.assets[$0] }, context: context,
                       library: library, undo: undo, place: place)
    }

    private func regroup() {
        let list = filter.apply(newestFirst ? assets : assets.reversed())
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
#endif
