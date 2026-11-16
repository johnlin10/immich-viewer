import SwiftUI

/// Everyone Immich recognised (hidden people left out), as round faces. Click one for their photos.
struct PeopleGrid: View {
    @Environment(Library.self) private var library

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
                }
            }
            .padding(20)
        }
        .overlay { Empty(count: library.people.count, error: library.collectionsError, title: "No People") }
        .navigationTitle("People")
        .navigationSubtitle("\(library.people.count) people")
    }
}

/// Own and shared albums as covers with name and count. Click one for its photos.
struct AlbumGrid: View {
    @Environment(Library.self) private var library

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
                }
            }
            .padding(20)
        }
        .overlay { Empty(count: library.albums.count, error: library.collectionsError, title: "No Albums") }
        .navigationTitle("Albums")
        .navigationSubtitle("\(library.albums.count) albums")
    }
}

/// One person's or album's photos in the usual grid, loaded when the page opens.
struct CollectionTimeline: View {
    @Environment(Library.self) private var library
    let title: String
    let filter: [String: String]
    @State private var assets: [Asset]?
    @State private var error: String?

    var body: some View {
        Group {
            if let assets {
                TimelineBrowser(title: title, subtitle: String(localized: "\(assets.count) items"), assets: assets, revision: 1)
            } else if let error {
                ContentUnavailableView("Can’t Load", systemImage: "exclamationmark.triangle", description: Text(error))
                    .navigationTitle(title)
            } else {
                ProgressView().navigationTitle(title)
            }
        }
        .task {
            do { assets = try await library.assets(filter) } catch { self.error = error.localizedDescription }
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
            .task(id: id) {
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
