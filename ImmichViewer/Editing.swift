import MapKit
import SwiftUI

/// Which photos a grid shows, for the actions that only make sense there.
enum BrowserContext: Hashable {
    case library
    case person(String)
    case album(String)
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
}

/// The chosen photos' menu: right-click in the grid, ⋯ in the photo view.
struct PhotoMenu: View {
    let library: Library
    let count: Int
    let allFavorite: Bool
    let context: BrowserContext
    let perform: (PhotoAction) -> Void

    var body: some View {
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
        if case .album = context {
            Button("Remove from Album", systemImage: "rectangle.stack.badge.minus") { perform(.removeFromAlbum) }
            if count == 1 { Button("Make Album Cover", systemImage: "photo.badge.checkmark") { perform(.makeCover) } }
        }
        if case .person = context, count == 1 {
            Button("Make Profile Photo", systemImage: "person.crop.circle") { perform(.makeProfilePhoto) }
        }
        Divider()
        Button("Adjust Date and Time…", systemImage: "calendar") { perform(.adjustDate) }
        Button("Set Location…", systemImage: "mappin.and.ellipse") { perform(.setLocation) }
        Divider()
        Button("Archive", systemImage: "archivebox") { perform(.archive) }
        Button("Delete…", systemImage: "trash") { perform(.trash) }
    }
}

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

    var id: String {
        switch self {
        case .date(let ids, _): "date" + (ids.first ?? "")
        case .location(let ids, _): "location" + (ids.first ?? "")
        case .newAlbum(let ids): "album" + (ids.first ?? "")
        case .editAlbum(let album): "album" + album.id
        case .editPerson(let person): "person" + person.id
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
            .frame(width: 520, height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(notFound ? String(localized: "No place found.") : pin.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) }
                 ?? String(localized: "Click the map to place the pin."))
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
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
        .frame(width: 360)
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
        .frame(width: 360)
        .sheetButtons(title: "Edit Person", canSave: true) {
            var new = person
            new.name = name.trimmingCharacters(in: .whitespaces)
            new.birthDate = hasBirthday ? birthday.formatted(Self.day) : nil
            onSave(new)
        }
    }
}

extension View {
    /// A sheet's title above the content and Cancel / Save below it. Save runs `save` and closes the sheet.
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
    }
}
