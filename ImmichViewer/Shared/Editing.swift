import MapKit
import SwiftUI
#if os(iOS)
import Photos
import UniformTypeIdentifiers
#endif

/// Which photos a grid shows, for the actions that only make sense there.
enum BrowserContext: Hashable {
    case library
    case person(String)
    case album(String)
    case tag(String)
    case archive
    case trash
    /// Search results: in the order they came, without date groups.
    case search
}

/// Something done to the chosen photos, from the right-click menu, the keyboard or the photo view.
enum PhotoAction {
    /// Into Favorites, or out if they all are already.
    case favorite
    case archive
    case trash
    case add(album: String)
    case newAlbum
    case adjustDate
    case setLocation
    case removeFromAlbum
    case makeCover
    case makeProfilePhoto
    case unarchive
    case restore
    case download
    case addTag
    case removeTag
    /// Degrees clockwise.
    case rotate(Int)
    /// A face in the photo is someone else's.
    case changePerson(face: String, from: String)
}

/// The chosen photos' menu: right-click in the grid, ⋯ in the photo view.
struct PhotoMenu: View {
    let library: Library
    let count: Int
    let allFavorite: Bool
    let context: BrowserContext
    let perform: (PhotoAction) -> Void

    var body: some View {
        if context == .trash {
            Button("Restore", systemImage: "arrow.uturn.backward") { perform(.restore) }
            #if os(macOS)
            Button("Download", systemImage: "arrow.down.circle") { perform(.download) }
            #endif
            Divider()
            Button("Delete Permanently…", systemImage: "trash", role: .destructive) { perform(.trash) }
        } else {
            Button(allFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: allFavorite ? "heart.slash" : "heart") {
                perform(.favorite)
            }
            Menu("Add to Album", systemImage: "rectangle.stack.badge.plus") {
                Button("New Album…") { perform(.newAlbum) }
                Divider()
                ForEach(library.albums) { album in
                    Button(album.albumName) { perform(.add(album: album.id)) }
                }
            }
            Button("Add Tag…", systemImage: "tag") { perform(.addTag) }
            if case .album = context {
                Button("Remove from Album", systemImage: "rectangle.stack.badge.minus") { perform(.removeFromAlbum) }
                if count == 1 { Button("Make Album Cover", systemImage: "photo.badge.checkmark") { perform(.makeCover) } }
            }
            if case .tag = context {
                Button("Remove Tag", systemImage: "tag.slash") { perform(.removeTag) }
            }
            if case .person = context, count == 1 {
                Button("Make Profile Photo", systemImage: "person.crop.circle") { perform(.makeProfilePhoto) }
            }
            Divider()
            Button("Rotate Left", systemImage: "rotate.left") { perform(.rotate(270)) }
            Button("Rotate Right", systemImage: "rotate.right") { perform(.rotate(90)) }
            Button("Adjust Date and Time…", systemImage: "calendar") { perform(.adjustDate) }
            Button("Set Location…", systemImage: "mappin.and.ellipse") { perform(.setLocation) }
            Divider()
            #if os(iOS)
            Button("Share…", systemImage: "square.and.arrow.up") { perform(.download) }
            #else
            Button("Download", systemImage: "arrow.down.circle") { perform(.download) }
            #endif
            if context == .archive {
                Button("Unarchive", systemImage: "archivebox") { perform(.unarchive) }
            } else {
                Button("Archive", systemImage: "archivebox") { perform(.archive) }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) { perform(.trash) }
        }
    }
}

/// Does what a photo menu asks: small changes at once, the rest after a sheet or a confirmation.
/// Each page or photo view with these menus keeps one, and shows its sheets and alerts with `.photoEditor(_:)`.
@MainActor @Observable
final class PhotoEditor {
    var sheet: EditSheet?
    /// Photos waiting for Delete to be confirmed.
    var trashing: [String]?
    /// Photos waiting for Delete Permanently to be confirmed; empty for the whole trash.
    var purging: [String]?
    var deletingAlbum: Album?
    var deletingTag: Tag?

    /// Does `action` to `assets`, on a page showing `context`. `place`: where the photo is now, from the photo view.
    func perform(_ action: PhotoAction, on assets: [Asset], context: BrowserContext, library: Library, undo: UndoManager?,
                 place: CLLocationCoordinate2D? = nil) {
        let ids = assets.map(\.id)
        guard let first = assets.first else { return }
        switch action {
        case .favorite:
            let all = assets.allSatisfy { $0.isFavorite == true }
            Task { await library.favorite(ids, !all, undo: undo) }
        case .archive: Task { await library.archive(ids, true, undo: undo) }
        case .trash:
            if context == .trash { purging = ids } else { trashing = ids }
        case .unarchive: Task { await library.archive(ids, false, undo: undo) }
        case .restore: Task { await library.restore(ids, undo: undo) }
        case .download:
            #if os(iOS)
            Task { share(await library.download(assets)) }
            #else
            Task { await library.download(assets) }
            #endif
        case .addTag: sheet = .tag(ids)
        case .removeTag:
            if case .tag(let id) = context, let tag = library.tags.first(where: { $0.id == id }) {
                Task { await library.untag(ids, tag, undo: undo) }
            }
        case .rotate(let angle): Task { await library.rotate(ids, by: angle, undo: undo) }
        case let .changePerson(face, old): sheet = .changePerson(face: face, from: old)
        case .add(let album): Task { await library.add(ids, to: album, undo: undo) }
        case .newAlbum: sheet = .newAlbum(ids)
        case .adjustDate: sheet = .date(ids, first.date)
        case .setLocation: sheet = .location(ids, place)
        case .removeFromAlbum:
            if case .album(let album) = context { Task { await library.remove(ids, from: album, undo: undo) } }
        case .makeCover:
            if case .album(let id) = context, let old = library.albums.first(where: { $0.id == id }) {
                var new = old
                new.albumThumbnailAssetId = ids[0]
                Task { await library.update(new, was: old, undo: undo) }
            }
        case .makeProfilePhoto:
            if case .person(let person) = context { Task { await library.setProfilePhoto(person, from: ids[0]) } }
        }
    }
}

extension View {
    /// The editor's sheets and confirmations. Deleting the album or tag, or hiding the person, the page shows closes it.
    func photoEditor(_ editor: PhotoEditor, library: Library, undo: UndoManager?) -> some View {
        modifier(PhotoEditorSheets(editor: editor, library: library, undo: undo))
    }
}

private struct PhotoEditorSheets: ViewModifier {
    @Bindable var editor: PhotoEditor
    let library: Library
    let undo: UndoManager?
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .editSheet($editor.sheet, library: library, undo: undo)
            .alert(editor.trashing?.count == 1 ? "Delete This Photo?" : "Delete \(editor.trashing?.count ?? 0) Photos?",
                   isPresented: Binding { editor.trashing != nil } set: { if !$0 { editor.trashing = nil } }) {
                Button("Delete", role: .destructive) {
                    if let ids = editor.trashing { Task { await library.trash(ids, undo: undo) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                #if os(macOS)
                Text(library.trashEnabled
                     ? "They go to the server’s trash, which keeps them for 30 days unless the server is set otherwise. ⌘Z puts them back."
                     : "The server’s trash is turned off, so they are deleted for good.")
                #else
                Text(library.trashEnabled
                     ? "They go to the server’s trash, which keeps them for 30 days unless the server is set otherwise."
                     : "The server’s trash is turned off, so they are deleted for good.")
                #endif
            }
            .alert(editor.purging?.isEmpty == true ? "Empty the Trash?" : editor.purging?.count == 1 ? "Delete This Photo Permanently?"
                   : "Delete \(editor.purging?.count ?? 0) Photos Permanently?",
                   isPresented: Binding { editor.purging != nil } set: { if !$0 { editor.purging = nil } }) {
                Button(editor.purging?.isEmpty == true ? "Empty Trash" : "Delete Permanently", role: .destructive) {
                    guard let ids = editor.purging else { return }
                    Task { ids.isEmpty ? await library.emptyTrash() : await library.deleteForever(ids) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can’t be undone.")
            }
            .alert("Delete This Album?", isPresented: Binding { editor.deletingAlbum != nil } set: { if !$0 { editor.deletingAlbum = nil } }) {
                Button("Delete", role: .destructive) {
                    guard let album = editor.deletingAlbum else { return }
                    Task {
                        await library.delete(album)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The photos in it stay in your library.")
            }
            .alert("Delete This Tag?", isPresented: Binding { editor.deletingTag != nil } set: { if !$0 { editor.deletingTag = nil } }) {
                Button("Delete", role: .destructive) {
                    guard let tag = editor.deletingTag else { return }
                    Task {
                        await library.delete(tag)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The photos with it stay in your library.")
            }
    }
}

/// The ⋯ menu's part for an album, person, tag or trash page.
struct CollectionMenu: View {
    let library: Library
    let context: BrowserContext
    let editor: PhotoEditor
    let undo: UndoManager?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch context {
        case .album(let id):
            if let album = library.albums.first(where: { $0.id == id }) {
                Divider()
                Button("Edit Album…", systemImage: "pencil") { editor.sheet = .editAlbum(album) }
                Button("Delete Album…", systemImage: "trash", role: .destructive) { editor.deletingAlbum = album }
            }
        case .person(let id):
            if let person = library.people.first(where: { $0.id == id }) {
                Divider()
                Button("Edit Person…", systemImage: "pencil") { editor.sheet = .editPerson(person) }
                Button("Merge With…", systemImage: "person.2") { editor.sheet = .merge(person) }
                Button("Hide Person", systemImage: "eye.slash") {
                    Task {
                        await library.update(person, hidden: true, was: person, undo: undo)
                        dismiss()
                    }
                }
            }
        case .tag(let id):
            if let tag = library.tags.first(where: { $0.id == id }) {
                Divider()
                Button("Delete Tag…", systemImage: "trash", role: .destructive) { editor.deletingTag = tag }
            }
        case .trash:
            Divider()
            Button("Restore All", systemImage: "arrow.uturn.backward") { Task { await library.restoreAll() } }
            Button("Empty Trash…", systemImage: "trash", role: .destructive) { editor.purging = [] }
        case .library, .archive, .search:
            EmptyView()
        }
    }
}

/// Over the middle of the window while originals download (to share, or to Downloads) or files upload, with Cancel.
struct TransferPanel: View {
    @Environment(Library.self) private var library

    var body: some View {
        ZStack {
            if let progress = library.transfer {
                VStack(spacing: 14) {
                    let step = library.transferStep, total = Int(progress.totalUnitCount)
                    Text(library.transferIsUpload ? String(localized: "Uploading \(step) of \(total)")
                                                  : String(localized: "Downloading \(step) of \(total)"))
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    ProgressView(progress).labelsHidden()
                    Button("Cancel", role: .cancel) { progress.cancel() }
                        .buttonStyle(.glass)
                }
                .padding(20)
                .frame(width: 260)
                .glassEffect(in: .rect(cornerRadius: 24))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: library.transfer != nil)
        .animation(.smooth, value: library.transferStep)
    }
}

/// Over a page while files are dragged onto it: an outline, and what dropping will do (into `album`, an id, if given).
struct DropHighlight: View {
    @Environment(Library.self) private var library
    let album: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 4).padding(4)
            Group {
                if let album {
                    let name = library.albums.first { $0.id == album }?.albumName ?? ""
                    Text("Drop to Add to “\(name)”")
                } else {
                    Text("Drop to Upload")
                }
            }
            .font(.headline)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

#if os(iOS)
/// The share sheet for downloaded files, over whatever is showing. Their folder goes once the sheet closes.
func share(_ files: [URL]) {
    guard let first = files.first,
          let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
          var top = scene.keyWindow?.rootViewController else { return }
    while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
    let pairs = livePairs(files)
    let sheet = UIActivityViewController(activityItems: files, applicationActivities: pairs.isEmpty ? nil : [SaveToPhotos(files)])
    if !pairs.isEmpty { sheet.excludedActivityTypes = [.saveToCameraRoll] } // it would save a Live Photo as two items
    sheet.popoverPresentationController?.sourceView = top.view // iPad: from the middle
    sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
    sheet.popoverPresentationController?.permittedArrowDirections = []
    sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
    top.present(sheet, animated: true)
}

/// Stills that have a video of the same name beside them (a Live Photo, as `Library.download` saves one), with that video.
private func livePairs(_ files: [URL]) -> [URL: URL] {
    let videos = Dictionary(files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
        .map { ($0.deletingPathExtension(), $0) }, uniquingKeysWith: { a, _ in a })
    var pairs: [URL: URL] = [:]
    for file in files where UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true {
        pairs[file] = videos[file.deletingPathExtension()]
    }
    return pairs
}

/// Save to Photos that keeps a Live Photo live, in place of the built-in one, which saves its still and video apart.
private final class SaveToPhotos: UIActivity {
    let files: [URL]
    init(_ files: [URL]) { self.files = files }
    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { .init("ImmichViewer.SaveToPhotos") }
    override var activityTitle: String? { String(localized: "Save to Photos") }
    override var activityImage: UIImage? { UIImage(systemName: "square.and.arrow.down") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        let files = files
        Task {
            guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { return activityDidFinish(false) }
            do {
                try await Self.save(files, live: true)
            } catch { // a video the still doesn't recognize as its own (some motion photos): save them apart
                try? await Self.save(files, live: false)
            }
            activityDidFinish(true)
        }
    }

    private static func save(_ files: [URL], live: Bool) async throws {
        let pairs = live ? livePairs(files) : [:]
        let paired = Set(pairs.values)
        try await PHPhotoLibrary.shared().performChanges {
            for file in files where !paired.contains(file) {
                let request = PHAssetCreationRequest.forAsset()
                let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
                request.addResource(with: isImage ? .photo : .video, fileURL: file, options: nil)
                if let video = pairs[file] { request.addResource(with: .pairedVideo, fileURL: video, options: nil) }
            }
        }
    }
}
#endif

/// A sheet for a change that needs more than a click.
enum EditSheet: Identifiable {
    /// The photos and the first one's date.
    case date([String], Date)
    /// The photos and where the first one is now, if known.
    case location([String], CLLocationCoordinate2D?)
    /// A new album with these photos in it (none from the Albums page).
    case newAlbum([String])
    case editAlbum(Album)
    case editPerson(Person)
    case tag([String])
    /// Someone else becomes this person.
    case merge(Person)
    case changePerson(face: String, from: String)

    var id: String {
        switch self {
        case .date(let ids, _): "date" + (ids.first ?? "")
        case .location(let ids, _): "location" + (ids.first ?? "")
        case .newAlbum(let ids): "album" + (ids.first ?? "")
        case .editAlbum(let album): "album" + album.id
        case .editPerson(let person): "person" + person.id
        case .tag(let ids): "tag" + (ids.first ?? "")
        case .merge(let person): "merge" + person.id
        case .changePerson(let face, _): "face" + face
        }
    }
}

extension View {
    /// Shows `sheet` and makes its change, with undo in `undo` (the window's, not the sheet's).
    func editSheet(_ sheet: Binding<EditSheet?>, library: Library, undo: UndoManager?) -> some View {
        self.sheet(item: sheet) { sheet in
            switch sheet {
            case let .date(ids, date):
                DateSheet(count: ids.count, original: date) { minutes in
                    Task { await library.shiftDates(ids, minutes: minutes, undo: undo) }
                }
            case let .location(ids, old):
                LocationSheet(start: old) { place in
                    Task { await library.locate(ids, at: place, was: old, undo: undo) }
                }
            case let .newAlbum(ids):
                AlbumSheet(title: "New Album", name: "", text: "") { name, text in
                    Task { await library.createAlbum(name, description: text, with: ids) }
                }
            case let .editAlbum(album):
                AlbumSheet(title: "Edit Album", name: album.albumName, text: album.description ?? "") { name, text in
                    var new = album
                    new.albumName = name
                    new.description = text
                    Task { await library.update(new, was: album, undo: undo) }
                }
            case let .editPerson(person):
                PersonSheet(person: person) { new in
                    Task { await library.update(new, was: person, undo: undo) }
                }
            case let .tag(ids):
                TagSheet(tags: library.tags, ids: ids, undo: undo) { name in
                    Task { await library.tag(ids, name, undo: undo) }
                }
            case let .merge(person):
                PersonPicker(title: "Merge People", note: "The person you choose becomes \(person.name.isEmpty ? String(localized: "Unnamed") : person.name): their photos move over and they are gone. This can’t be undone.",
                             people: library.people.filter { $0.id != person.id }) { other in
                    Task { await library.merge([other.id], into: person.id) }
                }
            case let .changePerson(face, old):
                PersonPicker(title: "Change Person", note: "Who is this?", people: library.people.filter { $0.id != old }) { new in
                    Task { await library.reassign(face: face, to: new.id, from: old, undo: undo) }
                }
            }
        }
    }
}

/// Dates and times shown as they were on the camera's clock, the way `Asset.date` stores them.
private let wallClock = TimeZone.gmt

/// Moves the photos' dates: the first photo gets the new date, the others move by the same amount.
private struct DateSheet: View {
    let count: Int
    let original: Date
    let onSave: (Int) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(count: Int, original: Date, onSave: @escaping (Int) -> Void) {
        self.count = count
        self.original = original
        self.onSave = onSave
        _date = State(initialValue: original)
    }

    var body: some View {
        Form {
            DatePicker("Date and time", selection: $date)
            LabeledContent("Original", value: original.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: wallClock)))
            if count > 1 {
                Text("This is the first photo’s date. All \(count) photos move by the same amount.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .environment(\.timeZone, wallClock)
        .sheetButtons(title: "Adjust Date and Time", canSave: date != original) {
            onSave(Int((date.timeIntervalSince(original) / 60).rounded()))
        }
    }
}

/// Puts the photos on the map: search for a place or click the map.
private struct LocationSheet: View {
    let start: CLLocationCoordinate2D?
    let onSave: (CLLocationCoordinate2D) -> Void
    @State private var pin: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition
    @State private var query = ""
    @State private var notFound = false

    init(start: CLLocationCoordinate2D?, onSave: @escaping (CLLocationCoordinate2D) -> Void) {
        self.start = start
        self.onSave = onSave
        _pin = State(initialValue: start)
        _camera = State(initialValue: start.map { .region(MKCoordinateRegion(center: $0, latitudinalMeters: 5000, longitudinalMeters: 5000)) }
                        ?? .automatic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search for a place", text: $query)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            MapReader { map in
                Map(position: $camera) {
                    if let pin { Marker("", coordinate: pin) }
                }
                .onTapGesture { point in pin = map.convert(point, from: .local) }
            }
            #if os(macOS)
            .frame(width: 520, height: 340)
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(notFound ? String(localized: "No place found.") : pin.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) }
                 ?? String(localized: "Click the map to place the pin."))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        #if os(iOS)
        .padding()
        #endif
        .sheetButtons(title: "Set Location", canSave: pin != nil, returnSaves: false) { // Return searches
            if let pin { onSave(pin) }
        }
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let item = try? await MKLocalSearch(request: request).start().mapItems.first
        notFound = item == nil
        guard let item else { return }
        pin = item.location.coordinate
        camera = .region(MKCoordinateRegion(center: item.location.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000))
    }
}

private struct AlbumSheet: View {
    let title: LocalizedStringKey
    let onSave: (String, String) -> Void
    @State private var name: String
    @State private var text: String

    init(title: LocalizedStringKey, name: String, text: String, onSave: @escaping (String, String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: name)
        _text = State(initialValue: text)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Description", text: $text, axis: .vertical).lineLimit(3...6)
        }
        #if os(macOS)
        .frame(width: 360)
        #endif
        .sheetButtons(title: title, canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
            onSave(name.trimmingCharacters(in: .whitespaces), text)
        }
    }
}

private struct PersonSheet: View {
    let person: Person
    let onSave: (Person) -> Void
    @State private var name: String
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    private static let day: Date.ISO8601FormatStyle = .iso8601.year().month().day()

    init(person: Person, onSave: @escaping (Person) -> Void) {
        self.person = person
        self.onSave = onSave
        _name = State(initialValue: person.name)
        let date = person.birthDate.flatMap { try? Date(String($0.prefix(10)), strategy: Self.day) }
        _hasBirthday = State(initialValue: date != nil)
        _birthday = State(initialValue: date ?? Date(timeIntervalSince1970: 0))
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Toggle("Birthday", isOn: $hasBirthday)
            if hasBirthday {
                DatePicker("Born on", selection: $birthday, in: ...Date.now, displayedComponents: .date)
            }
        }
        .environment(\.timeZone, wallClock)
        #if os(macOS)
        .frame(width: 360)
        #endif
        .sheetButtons(title: "Edit Person", canSave: true) {
            var new = person
            new.name = name.trimmingCharacters(in: .whitespaces)
            new.birthDate = hasBirthday ? birthday.formatted(Self.day) : nil
            onSave(new)
        }
    }
}

/// A tag name, new or one of the existing ones, over the tags the photos have already (✕ takes one off them all).
private struct TagSheet: View {
    let tags: [Tag]
    let ids: [String]
    let undo: UndoManager?
    let onSave: (String) -> Void
    @Environment(Library.self) private var library
    @State private var name = ""
    /// The photos' tags, nil until loaded.
    @State private var added: [Tag]?

    var body: some View {
        let have = Set((added ?? []).map(\.id))
        let free = tags.filter { !have.contains($0.id) }
        let query = free.contains { $0.value == name } ? "" : name // one picked: still show the others
        let shown = free.filter { query.isEmpty || $0.value.localizedCaseInsensitiveContains(query) }
        Form {
            SwiftUI.Section {
                TextField("Tag", text: $name, prompt: Text("Trips/Japan"))
                    #if os(macOS)
                    .textInputSuggestions {
                        ForEach(shown.prefix(12)) { Text($0.value).textInputCompletion($0.value) }
                    }
                    #endif
                Text("A slash makes a tag inside another one.").font(.callout).foregroundStyle(.secondary)
            }
            if let added, !added.isEmpty {
                SwiftUI.Section(ids.count == 1 ? "On This Photo" : "On These Photos") {
                    ForEach(added) { tag in
                        HStack {
                            Label(tag.value, systemImage: "tag.fill")
                            Spacer()
                            Button("Remove Tag", systemImage: "xmark.circle.fill") { remove(tag) }
                                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        #if os(iOS)
                        .swipeActions { Button("Remove Tag", systemImage: "tag.slash", role: .destructive) { remove(tag) } }
                        #endif
                    }
                }
            }
            #if os(iOS)
            if !shown.isEmpty { // no completion menu on iOS: the other tags to pick from, narrowed as you type
                SwiftUI.Section("Tags") {
                    ForEach(shown.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }) { tag in
                        Button { name = tag.value } label: {
                            HStack {
                                Label(tag.value, systemImage: "tag").foregroundStyle(.primary)
                                Spacer()
                                if tag.value == name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(width: 360)
        #endif
        .task { added = await library.tags(on: ids) }
        .sheetButtons(title: "Add Tag", canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
            onSave(name.trimmingCharacters(in: .whitespaces))
        }
    }

    private func remove(_ tag: Tag) {
        withAnimation { added?.removeAll { $0.id == tag.id } }
        Task { await library.untag(ids, tag, undo: undo) }
    }
}

/// Picks one person, by face and name.
private struct PersonPicker: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey
    let people: [Person]
    let onSave: (Person) -> Void
    @Environment(Library.self) private var library
    @State private var chosen: Person.ID?
    @State private var query = ""

    var body: some View {
        #if os(iOS)
        List {
            SwiftUI.Section {
                ForEach(people.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { person in
                    Button { chosen = person.id } label: {
                        HStack(spacing: 10) {
                            Thumb(id: person.id, store: library.faces).frame(width: 36, height: 36).clipShape(Circle())
                            Text(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                            Spacer()
                            if chosen == person.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(note).textCase(nil)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .sheetButtons(title: title, canSave: chosen != nil) {
            if let person = people.first(where: { $0.id == chosen }) { onSave(person) }
        }
        #else
        VStack(alignment: .leading, spacing: 10) {
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $query)
            List(people.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, selection: $chosen) { person in
                HStack(spacing: 8) {
                    Thumb(id: person.id, store: library.faces).frame(width: 28, height: 28).clipShape(Circle())
                    Text(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                        .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                }
            }
            .frame(height: 300)
        }
        .frame(width: 360)
        .sheetButtons(title: title, canSave: chosen != nil) {
            if let person = people.first(where: { $0.id == chosen }) { onSave(person) }
        }
        #endif
    }
}

extension View {
    /// A sheet's title above the content and Cancel / Save below it (on iOS, in the navigation bar). Save runs `save`
    /// and closes the sheet.
    fileprivate func sheetButtons(title: LocalizedStringKey, canSave: Bool, returnSaves: Bool = true,
                                  save: @escaping () -> Void) -> some View {
        modifier(SheetButtons(title: title, canSave: canSave, returnSaves: returnSaves, save: save))
    }
}

private struct SheetButtons: ViewModifier {
    let title: LocalizedStringKey
    let canSave: Bool
    let returnSaves: Bool
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", role: .confirm) {
                            save()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(returnSaves ? .defaultAction : nil)
                .disabled(!canSave)
            }
        }
        .padding(20)
        #endif
    }
}
