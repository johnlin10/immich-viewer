import SwiftUI

/// People, albums, tags and the utilities on one page, like Photos' Collections. Each heading opens the full page.
struct CollectionsPage: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undo
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @AppStorage("albumSort") private var albumSort = AlbumSort.recent
    /// Settings opens from this page's top right, as a sheet.
    let onSettings: () -> Void
    // the full pages' long-press menus, with their sheets and alerts
    @State private var sheet: EditSheet?
    @State private var deletingAlbum: Album?
    @State private var deletingTag: Tag?

    var body: some View {
        #if os(iOS)
        let wide = sizeClass == .regular // smaller items on iPhone, so a few more show
        #else
        let wide = true
        #endif
        let face: CGFloat = wide ? 110 : 80, cover: CGFloat = wide ? 180 : 140
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                section("People", empty: library.people.isEmpty, page: .people) {
                    ForEach(library.people.prefix(40)) { person in
                        NavigationLink(value: person) {
                            VStack(spacing: 8) {
                                Thumb(id: person.id, store: library.faces)
                                    .frame(width: face, height: face)
                                    .clipShape(Circle())
                                Text(person.name.isEmpty ? " " : person.name).lineLimit(1)
                            }
                            .frame(width: face + 10)
                        }
                        .contextMenu {
                            Button("Edit Person…", systemImage: "pencil") { sheet = .editPerson(person) }
                            Button("Merge With…", systemImage: "person.2") { sheet = .merge(person) }
                            Button("Hide Person", systemImage: "eye.slash") {
                                Task { await library.update(person, hidden: true, was: person, undo: undo) }
                            }
                        }
                    }
                }
                section("Albums", empty: library.albums.isEmpty, page: .albums) {
                    ForEach(albumSort.apply(library.albums).prefix(40)) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 4) {
                                Thumb(id: album.albumThumbnailAssetId ?? "", store: library.thumbs)
                                    .frame(width: cover, height: cover)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .padding(.bottom, 4)
                                Text(album.albumName).lineLimit(1)
                                Text("\(album.assetCount) items").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: cover, alignment: .leading)
                        }
                        .contextMenu {
                            Button("Edit Album…", systemImage: "pencil") { sheet = .editAlbum(album) }
                            Button("Delete Album…", systemImage: "trash", role: .destructive) { deletingAlbum = album }
                        }
                    }
                }
                section("Tags", empty: library.tags.isEmpty, page: .tags) {
                    ForEach(library.tags.prefix(60)) { tag in
                        NavigationLink(value: tag) {
                            Label(tag.value, systemImage: "tag")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.quaternary, in: .capsule)
                        }
                        .contextMenu { Button("Delete Tag…", systemImage: "trash", role: .destructive) { deletingTag = tag } }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Utilities").font(.title2.bold())
                    VStack(spacing: 0) {
                        NavigationLink(value: BrowserContext.archive) { UtilityRow(title: "Archive", symbol: "archivebox") }
                        Divider().padding(.leading, 62)
                        NavigationLink(value: BrowserContext.trash) { UtilityRow(title: "Trash", symbol: "trash") }
                    }
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, wide ? 24 : 16) // in line with the title
            .padding(.vertical, 12)
        }
        .overlay { if library.collectionsError != nil, library.people.isEmpty, library.albums.isEmpty {
            ContentUnavailableView("Can’t Load", systemImage: "exclamationmark.triangle",
                                   description: Text("The key needs the person.read and album.read permissions."))
        } }
        .editSheet($sheet, library: library, undo: undo)
        .alert("Delete This Album?", isPresented: Binding { deletingAlbum != nil } set: { if !$0 { deletingAlbum = nil } }) {
            Button("Delete", role: .destructive) {
                if let album = deletingAlbum { Task { await library.delete(album) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos in it stay in your library.")
        }
        .alert("Delete This Tag?", isPresented: Binding { deletingTag != nil } set: { if !$0 { deletingTag = nil } }) {
            Button("Delete", role: .destructive) {
                if let tag = deletingTag { Task { await library.delete(tag) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos with it stay in your library.")
        }
        .pageBar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Settings", systemImage: "gearshape", action: onSettings) }
        }
        .navigationTitle("Collections")
    }

    /// A heading that opens the full page, over one row of items that scrolls sideways.
    private func section<Items: View>(_ title: LocalizedStringKey, empty: Bool, page: CollectionList,
                                                       @ViewBuilder items: () -> Items) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: page) {
                HStack(spacing: 6) {
                    Text(title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.title3.bold()).foregroundStyle(.secondary)
                }
            }
            if empty {
                Text("None").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) { items() }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }
}

/// The full pages Collections' headings open. A value, like the rows' links: a view-destination link in the same
/// stack gets pushed again when a row's value is pushed on top of it.
enum CollectionList: Hashable { case people, albums, tags }

extension View {
    /// A person, album or tag opens its photos; so do Archive and Trash.
    func collectionDestinations() -> some View {
        navigationDestination(for: Person.self) { CollectionTimeline(context: .person($0.id), fallbackTitle: $0.name) }
            .navigationDestination(for: Album.self) { CollectionTimeline(context: .album($0.id), fallbackTitle: $0.albumName) }
            .navigationDestination(for: Tag.self) { CollectionTimeline(context: .tag($0.id), fallbackTitle: $0.value) }
            .navigationDestination(for: CollectionList.self) {
                switch $0 {
                case .people: PeopleGrid()
                case .albums: AlbumGrid()
                case .tags: TagList()
                }
            }
            .navigationDestination(for: BrowserContext.self) { context in
                CollectionTimeline(context: context, fallbackTitle: context == .trash ? String(localized: "Trash") : String(localized: "Archive"))
            }
    }
}
