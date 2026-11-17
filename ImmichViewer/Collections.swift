import SwiftUI

/// Everyone Immich recognised (hidden people left out), as round faces. Click one for their photos.
struct PeopleGrid: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undo
    @State private var sheet: EditSheet?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 20) {
                ForEach(library.people) { person in
                    NavigationLink(value: person) {
                        VStack(spacing: 8) {
                            Thumb(id: person.id, store: library.faces)
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())
                            Text(person.name.isEmpty ? " " : person.name) // a blank line keeps rows even
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Person…") { sheet = .editPerson(person) }
                        Button("Merge With…") { sheet = .merge(person) }
                        Button("Hide Person") { Task { await library.update(person, hidden: true, was: person, undo: undo) } }
                    }
                }
            }
            .padding(20)
        }
        .editSheet($sheet, library: library, undo: undo)
        .overlay { Empty(count: library.people.count, error: library.collectionsError, title: "No People") }
        .navigationTitle("People")
        .navigationSubtitle("\(library.people.count) people")
    }
}

/// Own and shared albums as covers with name and count. Click one for its photos.
struct AlbumGrid: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undo
    @State private var sheet: EditSheet?
    @State private var deleting: Album?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(library.albums) { album in
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
                        Button("Edit Album…") { sheet = .editAlbum(album) }
                        Button("Delete Album…") { deleting = album }
                    }
                }
            }
            .padding(20)
        }
        .toolbar {
            Button { sheet = .newAlbum([]) } label: { Image(systemName: "plus") }
                .help("New Album")
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
        .navigationSubtitle("\(library.albums.count) albums")
    }
}

/// Every tag by its full path. Click one for its photos.
struct TagList: View {
    @Environment(Library.self) private var library
    @State private var deleting: Tag?

    var body: some View {
        List(library.tags) { tag in
            NavigationLink(value: tag) { Label(tag.value, systemImage: "tag") }
                .contextMenu { Button("Delete Tag…") { deleting = tag } }
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

    var body: some View {
        Group {
            if let assets {
                TimelineBrowser(title: title, subtitle: String(localized: "\(assets.count) items"), assets: assets, revision: loads,
                                context: context)
            } else if let error {
                ContentUnavailableView("Can’t Load", systemImage: "exclamationmark.triangle", description: Text(error))
                    .navigationTitle(title)
            } else {
                ProgressView().navigationTitle(title)
            }
        }
        .task(id: library.edits) {
            do {
                assets = try await library.assets(filter)
                loads += 1
            } catch {
                self.error = error.localizedDescription
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
