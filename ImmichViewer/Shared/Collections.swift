import SwiftUI

/// The filter button at the top right (on iOS, a submenu of ⋯): filled while a filter is on. Items are toggles; none
/// on shows everything.
struct FilterMenu<Items: View>: View {
    let active: Bool
    let clear: () -> Void
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
            Divider()
            Button("Clear Filters", systemImage: "xmark.circle", action: clear).disabled(!active)
        } label: {
            Label("Filter", systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .help("Filter")
    }
}

/// The sort button at the top right (on iOS, a submenu of ⋯): one choice, checked.
struct SortMenu<Value: Hashable, Items: View>: View {
    @Binding var selection: Value
    @ViewBuilder let items: Items

    var body: some View {
        #if os(iOS) // a submenu that shows the current choice, like the photo pages' Sort
        Picker(selection: $selection) { items } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .pickerStyle(.menu)
        #else
        Menu {
            Picker("Sort", selection: $selection) { items }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .help("Sort")
        #endif
    }
}

/// A list page's filter and sort: separate buttons on the Mac, one ⋯ menu on iOS as on the photo pages.
struct ListOptions<Items: View>: ToolbarContent {
    @ViewBuilder let items: Items

    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .primaryAction) {
            Menu { items } label: { Label("More", systemImage: "ellipsis") }
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) { items }
        #endif
    }
}

extension View {
    /// Every iOS page's bar alike: once the large title shrinks it sits on the left (iOS would centre it), and the content
    /// fades under it with a progressive blur (iOS picks a solid backdrop for lists and forms).
    func pageBar() -> some View {
        #if os(iOS)
        toolbarRole(.browser)
            .scrollEdgeEffectStyle(.soft, for: .top)
        #else
        self
        #endif
    }
}

/// "12 people · 3 shown" while a filter is on.
func countSubtitle(_ total: String, shown: Int, filtered: Bool) -> String {
    filtered ? total + " · " + String(localized: "\(shown) shown") : total
}

/// Everyone Immich recognised (hidden people left out), as round faces. Click one for their photos.
struct PeopleGrid: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undo
    @State private var sheet: EditSheet?
    @AppStorage("peopleSort") private var sort = PeopleSort.standard
    @AppStorage("peopleNamed") private var named = false
    @AppStorage("peopleUnnamed") private var unnamed = false
    @AppStorage("peopleBirthday") private var birthday = false

    private var filter: PeopleFilter { PeopleFilter(named: named, unnamed: unnamed, birthday: birthday) }

    var body: some View {
        let shown = sort.apply(filter.apply(library.people))
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 20) {
                ForEach(shown) { person in
                    NavigationLink(value: person) {
                        VStack(spacing: 8) {
                            Thumb(id: person.id, store: library.faces)
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())
                            VStack(spacing: 2) {
                                Text(person.name.isEmpty ? " " : person.name) // blank lines keep rows even
                                    .lineLimit(1)
                                Group {
                                    if let birthday = person.birthday() {
                                        Text("\(birthday.date.formatted(date: .numeric, time: .omitted)) · Age \(birthday.age)")
                                    } else {
                                        Text(verbatim: " ")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Person…", systemImage: "pencil") { sheet = .editPerson(person) }
                        Button("Merge With…", systemImage: "person.2") { sheet = .merge(person) }
                        Button("Hide Person", systemImage: "eye.slash") {
                            Task { await library.update(person, hidden: true, was: person, undo: undo) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .editSheet($sheet, library: library, undo: undo)
        .overlay { Empty(count: library.people.count, error: library.collectionsError, title: "No People") }
        .overlay {
            if filter.isActive, shown.isEmpty, !library.people.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .pageBar()
        .toolbar {
            ListOptions {
                FilterMenu(active: filter.isActive) { (named, unnamed, birthday) = (false, false, false) } items: {
                    Toggle(isOn: $named) { Label("Named", systemImage: "person.crop.circle.badge.checkmark") }
                    Toggle(isOn: $unnamed) { Label("Unnamed", systemImage: "person.crop.circle.badge.questionmark") }
                    Divider()
                    Toggle(isOn: $birthday) { Label("Has Birthday", systemImage: "birthday.cake") }
                }
                SortMenu(selection: $sort) {
                    Label("Default", systemImage: "list.bullet").tag(PeopleSort.standard)
                    Label("Name", systemImage: "textformat").tag(PeopleSort.name)
                    Label("Age, Youngest First", systemImage: "figure.child").tag(PeopleSort.youngest)
                    Label("Age, Oldest First", systemImage: "figure.walk").tag(PeopleSort.oldest)
                }
            }
        }
        .navigationTitle("People")
        .navigationSubtitle(countSubtitle(String(localized: "\(library.people.count) people"), shown: shown.count, filtered: filter.isActive))
    }
}

/// Own and shared albums as covers with name and count. Click one for its photos.
struct AlbumGrid: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undo
    @State private var sheet: EditSheet?
    @State private var deleting: Album?
    @AppStorage("albumSort") private var sort = AlbumSort.recent
    @AppStorage("albumsMine") private var mine = false
    @AppStorage("albumsShared") private var shared = false

    /// Mine and Shared are either-or; without knowing who owns what, there's no filter.
    private var filtered: Bool { library.ownedAlbums != nil && (mine || shared) }

    var body: some View {
        let owned = library.ownedAlbums
        let shown = sort.apply(library.albums.filter { album in
            guard let owned, mine != shared else { return true }
            return owned.contains(album.id) ? mine : shared
        })
        ScrollView {
            #if os(iOS) // above the albums, so they're never a long scroll away; the Mac has them in the sidebar
            VStack(spacing: 0) {
                NavigationLink(value: BrowserContext.archive) { UtilityRow(title: "Archive", symbol: "archivebox") }
                Divider().padding(.leading, 62)
                NavigationLink(value: BrowserContext.trash) { UtilityRow(title: "Trash", symbol: "trash") }
                Divider()
            }
            .buttonStyle(.plain)
            #endif
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(shown) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 4) {
                            Thumb(id: album.albumThumbnailAssetId ?? "", store: library.thumbs)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .padding(.bottom, 4)
                            Text(album.albumName).lineLimit(1)
                            Text("\(album.assetCount) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Album…", systemImage: "pencil") { sheet = .editAlbum(album) }
                        Button("Delete Album…", systemImage: "trash", role: .destructive) { deleting = album }
                    }
                }
            }
            .padding(20)
        }
        .pageBar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Album", systemImage: "plus") { sheet = .newAlbum([]) }
                    .help("New Album")
            }
            #if os(iOS)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            #endif
            ListOptions {
                if owned != nil {
                    FilterMenu(active: filtered) { (mine, shared) = (false, false) } items: {
                        Toggle(isOn: $mine) { Label("Mine", systemImage: "person") }
                        Toggle(isOn: $shared) { Label("Shared", systemImage: "person.2") }
                    }
                }
                SortMenu(selection: $sort) {
                    Label("Recent", systemImage: "clock").tag(AlbumSort.recent)
                    Label("Name", systemImage: "textformat").tag(AlbumSort.name)
                    Label("Item Count", systemImage: "photo.stack").tag(AlbumSort.count)
                }
            }
        }
        .overlay {
            if filtered, shown.isEmpty, !library.albums.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .editSheet($sheet, library: library, undo: undo)
        .alert("Delete This Album?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete", role: .destructive) {
                if let album = deleting { Task { await library.delete(album) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos in it stay in your library.")
        }
        .overlay { Empty(count: library.albums.count, error: library.collectionsError, title: "No Albums") }
        .navigationTitle("Albums")
        .navigationSubtitle(countSubtitle(String(localized: "\(library.albums.count) albums"), shown: shown.count, filtered: filtered))
    }
}

/// Every tag by its full path. Click one for its photos.
struct TagList: View {
    @Environment(Library.self) private var library
    @State private var deleting: Tag?
    @AppStorage("tagsAscending") private var ascending = true

    var body: some View {
        List(ascending ? library.tags : library.tags.reversed()) { tag in
            NavigationLink(value: tag) { Label(tag.value, systemImage: "tag") }
                .contextMenu { Button("Delete Tag…", systemImage: "trash", role: .destructive) { deleting = tag } }
                #if os(iOS)
                .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { deleting = tag } }
                #endif
        }
        .alert("Delete This Tag?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete", role: .destructive) {
                if let tag = deleting { Task { await library.delete(tag) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos with it stay in your library.")
        }
        .overlay { if library.tags.isEmpty { ContentUnavailableView("No Tags", systemImage: "tag") } }
        .pageBar()
        .toolbar {
            ListOptions {
                SortMenu(selection: $ascending) {
                    Label("Name, A to Z", systemImage: "a.square").tag(true)
                    Label("Name, Z to A", systemImage: "z.square").tag(false)
                }
            }
        }
        .navigationTitle("Tags")
        .navigationSubtitle("\(library.tags.count) tags")
    }
}

/// One person's or album's photos in the usual grid, loaded when the page opens and again after each change.
struct CollectionTimeline: View {
    @Environment(Library.self) private var library
    let context: BrowserContext
    /// The name it had when it was opened, in case it isn't in the list any more.
    let fallbackTitle: String
    @State private var assets: [Asset]?
    @State private var loads = 0
    @State private var error: String?

    private var title: String {
        let name = switch context {
        case .person(let id): library.people.first { $0.id == id }?.name ?? fallbackTitle
        case .album(let id): library.albums.first { $0.id == id }?.albumName ?? fallbackTitle
        case .tag(let id): library.tags.first { $0.id == id }?.value ?? fallbackTitle
        case .library, .archive, .trash: fallbackTitle
        }
        return name.isEmpty ? String(localized: "Unnamed") : name
    }

    /// The item count; on a person's page with a birthday, the birthday and age first.
    private func subtitle(_ count: Int) -> String {
        let items = String(localized: "\(count) items")
        guard case .person(let id) = context, let birthday = library.people.first(where: { $0.id == id })?.birthday() else { return items }
        return String(localized: "Born \(birthday.date.formatted(date: .long, time: .omitted)) · Age \(birthday.age)") + " · " + items
    }

    private var filter: [String: String] {
        switch context {
        case .person(let id): ["personId": id, "visibility": "timeline"]
        case .album(let id): ["albumId": id]
        case .tag(let id): ["tagId": id]
        case .library: ["visibility": "timeline"]
        case .archive: ["visibility": "archive"]
        case .trash: ["isTrashed": "true"]
        }
    }

    /// Until the photos are in: an album's count is known already; otherwise a placeholder of the same height, so the
    /// page doesn't jump when the count arrives.
    private var loadingSubtitle: String {
        if case .album(let id) = context, let album = library.albums.first(where: { $0.id == id }) { return subtitle(album.assetCount) }
        return String(localized: "Loading…")
    }

    var body: some View {
        // the grid and its toolbar from the start, so they come in with the push instead of popping in after the load
        TimelineBrowser(title: title, subtitle: assets.map { subtitle($0.count) } ?? loadingSubtitle, assets: assets ?? [],
                        revision: loads, context: context)
            .overlay {
                if let error {
                    ContentUnavailableView("Can’t Load", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if assets == nil {
                    ProgressView()
                }
            }
        .pageBar()
        .task(id: library.edits) {
            if assets == nil, let saved = library.savedAssets(filter) { // last time's at once; the server's replace them
                assets = saved
                loads += 1
            }
            do {
                let fresh = try await library.assets(filter)
                guard fresh != assets else { return } // unchanged: no regrouping, the grid stays put
                assets = fresh
                loads += 1
            } catch {
                if assets == nil { self.error = error.localizedDescription } // offline: last time's list is still worth showing
            }
        }
    }
}

/// A cached thumbnail filling its frame; grey until it loads.
struct Thumb: View {
    @Environment(Library.self) private var library
    let id: String
    let store: ThumbnailStore
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: [id, "\(library.edits)"]) { // again after a change, for a new profile photo or album cover
                guard !id.isEmpty, let api = library.api else { return }
                image = await store.image(id, pixels: 0, api: api)
            }
    }
}

#if os(iOS)
/// Archive or Trash under the albums, like Photos' Utilities.
private struct UtilityRow: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
        .contentShape(.rect)
    }
}
#endif

/// Shown over an empty people or album page: why it is empty.
private struct Empty: View {
    let count: Int
    let error: String?
    let title: LocalizedStringKey

    var body: some View {
        if count == 0 {
            if let error {
                ContentUnavailableView("Can’t Load", systemImage: "exclamationmark.triangle",
                                       description: Text("\(error)\nThe key needs the person.read and album.read permissions."))
            } else {
                ContentUnavailableView(title, systemImage: "photo.on.rectangle")
            }
        }
    }
}
