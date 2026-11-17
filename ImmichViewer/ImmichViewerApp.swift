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
                        TimelineBrowser(title: String(localized: "Library"), subtitle: library.status, assets: library.assets, revision: library.revision)
                    case .people:
                        NavigationStack {
                            PeopleGrid().navigationDestination(for: Person.self) { person in
                                CollectionTimeline(title: person.name.isEmpty ? String(localized: "Unnamed") : person.name,
                                                   filter: ["personId": person.id, "visibility": "timeline"])
                            }
                        }
                    case .albums:
                        NavigationStack {
                            AlbumGrid().navigationDestination(for: Album.self) { album in
                                CollectionTimeline(title: album.albumName, filter: ["albumId": album.id])
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 400)
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
                        PhotoViewer(library: library, assets: grid.assets, topInset: titleBar, bridge: bridge,
                                    start: viewer) { self.viewer = nil }
                    }
                }
        }
        // the single photo view puts its own date in the middle of the title bar
        .navigationTitle(viewer == nil ? title : "")
        .navigationSubtitle(viewer == nil ? subtitle : "")
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
    }

    private func regroup() {
        let list = newestFirst ? assets : assets.reversed()
        grid = GridData(assets: list, sections: makeSections(list, by: grouping), years: yearStarts(list), id: grid.id + 1)
    }
}

/// Floating controls over the bottom of the grid, one glass capsule per job.
/// Plain buttons inside the glass, so nothing has a second border.
struct BottomBar: View {
    @Binding var level: Int
    @Binding var grouping: Grouping
    @Namespace private var selection

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
                        Button { withAnimation(.snappy(duration: 0.25)) { grouping = option } } label: {
                            Text(option.label)
                                .padding(.horizontal, 14)
                                .frame(height: 28)
                                .foregroundStyle(grouping == option ? .white : .primary)
                                .background {
                                    if grouping == option {
                                        Capsule().fill(.tint)
                                            .matchedGeometryEffect(id: "selected", in: selection)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .accessibilityAddTraits(grouping == option ? .isSelected : [])
                    }
                }
                .modifier(GlassCapsule())
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

