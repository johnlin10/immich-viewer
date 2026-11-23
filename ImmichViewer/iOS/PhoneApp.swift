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

/// Days / Months / All beside the collapsed tab bar, like Photos' Years / Months / All Photos: a glass capsule as tall as
/// the round buttons beside it, whose darker piece of glass slides to the chosen option. It sits inside the tab bar,
/// behind its buttons, so it grows out from under the collapsed button and the bar covers it again as it expands.
/// ponytail: tabViewBottomAccessory brings its own platter and stays above the bar once it expands, so not that;
/// the collapsed button is a private view found by class name: no picker if a later iOS renames it
private struct TabBarGrouping: UIViewRepresentable {
    let allowed: Bool

    @Observable final class Model {
        var allowed = false
        var collapsed = false
        /// Between the collapsed tab button and the Search button, in the tab bar.
        var slot = CGRect.zero
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView()
        anchor.isHidden = true
        context.coordinator.anchor = anchor
        return anchor
    }

    func updateUIView(_ anchor: UIView, context: Context) { context.coordinator.model.allowed = allowed }

    final class Coordinator {
        let model = Model()
        weak var anchor: UIView?
        private weak var bar: UITabBar?
        private weak var button: UIView?
        private var watches: [NSKeyValueObservation] = []
        private var timer: Timer?

        init() {
            // the tab bar builds its collapsed button late and may rebuild it: look again now and then
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.attach() } }
        }

        deinit { timer?.invalidate() }

        private func attach() {
            guard let root = anchor?.window?.rootViewController, let bar = Self.tabBar(in: root) else { return }
            if bar !== self.bar {
                self.bar = bar
                let host = UIHostingController(rootView: Capsule(model: model))
                host.view.backgroundColor = .clear
                host.safeAreaRegions = []
                let holder = Holder(model: model)
                holder.frame = bar.bounds
                holder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.view.frame = holder.bounds
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                holder.addSubview(host.view)
                holder.host = host
                bar.insertSubview(holder, at: 0) // behind the buttons
            }
            guard let button = Self.subview(of: bar, named: "_UITabBarPlatterView"), button !== self.button,
                  let tabs = Self.subview(of: bar, named: "_UITabBarItemPlatterView") else { return }
            self.button = button
            // the collapsed button shows as the bar starts collapsing, but hides only once it has expanded again:
            // the whole bar showing again is the start of that
            watches = [
                button.observe(\.isHidden, options: .initial) { [weak self] button, _ in
                    MainActor.assumeIsolated { self?.update(collapsed: !button.isHidden) }
                },
                tabs.observe(\.isHidden) { [weak self] tabs, _ in
                    MainActor.assumeIsolated { if !tabs.isHidden { self?.update(collapsed: false) } }
                },
            ]
        }

        private func update(collapsed: Bool) {
            guard let bar, let button, collapsed != model.collapsed else { return }
            let search = Self.subview(of: bar, named: "_UITabBarAuxiliaryView").flatMap { Self.subview(of: $0, named: "_UITabBarPlatterView") }
            let end = search.map { $0.convert($0.bounds, to: bar).minX } ?? bar.bounds.maxX - button.frame.minX - button.frame.width
            let gap = 14.0
            model.slot = CGRect(x: button.frame.maxX + gap, y: button.frame.minY, width: end - gap * 2 - button.frame.maxX, height: button.frame.height)
            withAnimation(.spring(duration: 0.45, bounce: 0.15)) { model.collapsed = collapsed }
        }

        private static func tabBar(in controller: UIViewController) -> UITabBar? {
            if let tabs = controller as? UITabBarController { return tabs.tabBar }
            return controller.children.lazy.compactMap { tabBar(in: $0) }.first
        }

        private static func subview(of view: UIView, named name: String) -> UIView? {
            view.subviews.first { String(describing: type(of: $0)) == name }
        }
    }

    /// Lets touches through to the tab bar and the page, except on the capsule.
    private final class Holder: UIView {
        let model: Model
        var host: UIViewController?
        init(model: Model) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            model.allowed && model.collapsed && model.slot.contains(point) ? super.hitTest(point, with: event) : nil
        }
    }

    private struct Capsule: View {
        let model: Model
        @AppStorage("grouping") private var grouping = Grouping.day
        @State private var selected = Grouping.day
        /// The piece of glass swells as it slides, like the tab bar's.
        @State private var moving = false
        @Namespace private var glass
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            ZStack(alignment: .topLeading) {
                if model.allowed && model.collapsed {
                    picker
                        .frame(width: model.slot.width, height: model.slot.height)
                        .offset(x: model.slot.minX, y: model.slot.minY)
                        .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .onChange(of: grouping, initial: true) { old, new in
                guard old != new else { selected = new; return }
                withAnimation(.bouncy(duration: 0.4)) { selected = new; moving = true }
                withAnimation(.smooth(duration: 0.3).delay(0.2)) { moving = false }
            }
        }

        private var picker: some View {
            GlassEffectContainer {
                HStack(spacing: 0) {
                    ForEach(Grouping.allCases, id: \.self) { option in
                        Button { grouping = option } label: {
                            Text(option.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .matchedGeometryEffect(id: option, in: glass) // where the darker glass goes for this option
                        .accessibilityAddTraits(selected == option ? .isSelected : [])
                    }
                }
                .background {
                    // a plain darker fill at rest, a clear lens while it slides
                    SwiftUI.Capsule()
                        .fill(.black.opacity(moving ? 0 : scheme == .dark ? 0.35 : 0.1))
                        .glassEffect(moving ? .clear.interactive() : .identity, in: .capsule)
                        .scaleEffect(moving ? 1.15 : 1)
                        .matchedGeometryEffect(id: selected, in: glass, isSource: false)
                }
                .padding(4)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Group By"))
        }
    }
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
    @State private var tab = "library"

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
                TabView(selection: $tab) {
                    Tab("Library", systemImage: "photo.on.rectangle", value: "library") {
                        NavigationStack {
                            TimelineBrowser(title: String(localized: "Library"), subtitle: library.status, assets: library.assets,
                                            revision: library.revision, context: .library)
                                .collectionDestinations()
                        }
                    }
                    // people, albums, tags and the utilities on one page, like Photos
                    Tab("Collections", systemImage: "square.stack", value: "collections") {
                        NavigationStack { CollectionsPage { settingsShown = true }.collectionDestinations() }
                    }
                    if sizeClass == .regular { // iPad: memories, the albums and utilities in the sidebar too
                        Tab("Memories", systemImage: "memories", value: "memories") {
                            NavigationStack { MemoryGrid().collectionDestinations() }
                        }
                        .tabPlacement(.sidebarOnly)
                        TabSection("Albums") {
                            Tab("All Albums", systemImage: "rectangle.stack", value: "albums") {
                                NavigationStack { AlbumGrid().collectionDestinations() }
                            }
                            ForEach(library.albums) { album in
                                Tab(album.albumName, systemImage: "rectangle.stack", value: "album:" + album.id) {
                                    NavigationStack {
                                        CollectionTimeline(context: .album(album.id), fallbackTitle: album.albumName).collectionDestinations()
                                    }
                                }
                            }
                        }
                        .tabPlacement(.sidebarOnly)
                        TabSection("Utilities") {
                            Tab("Archive", systemImage: "archivebox", value: "archive") {
                                NavigationStack { CollectionTimeline(context: .archive, fallbackTitle: String(localized: "Archive")) }
                            }
                            Tab("Trash", systemImage: "trash", value: "trash") {
                                NavigationStack { CollectionTimeline(context: .trash, fallbackTitle: String(localized: "Trash")) }
                            }
                        }
                        .tabPlacement(.sidebarOnly)
                    }
                    // last: on iPhone a round button apart from the tab bar, that turns into the field, like Photos
                    Tab(value: "search", role: .search) { searchTab }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabViewSearchActivation(.searchTabSelection) // the Search tab opens with the field and keyboard up
                .tabBarMinimizeBehavior(.onScrollDown)
                .background { TabBarGrouping(allowed: sizeClass == .compact && tab == "library") }
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
