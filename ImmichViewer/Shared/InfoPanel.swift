import MapKit
import SwiftUI

/// ⌘I: when, what file, which camera, where and who, from the asset's EXIF in Immich.
/// On the Mac the description, stars, date and place can be changed here; without the edit actions (iOS) it only shows them.
struct InfoPanel: View {
    let asset: Asset
    let detail: AssetDetail?
    @Binding var typing: Bool
    /// A person was clicked: show their photos.
    let onPerson: (Person) -> Void
    var onDescribe: ((String) -> Void)?
    var onRate: ((Int?) -> Void)?
    var onDate: (() -> Void)?
    var onPlace: (() -> Void)?
    var onAddTag: (() -> Void)?
    var onUntag: ((Tag) -> Void)?
    var onChangePerson: ((Person) -> Void)?
    @State private var draft = ""
    @FocusState private var editing: Bool
    private static let dayStyle: Date.FormatStyle = {
        var s = Date.FormatStyle(date: .complete, time: .omitted)
        s.timeZone = .gmt
        return s
    }()
    private static let timeStyle: Date.FormatStyle = {
        var s = Date.FormatStyle(date: .omitted, time: .shortened)
        s.timeZone = .gmt
        return s
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let when = VStack(alignment: .leading, spacing: 2) {
                    Text(asset.date.formatted(Self.dayStyle)).font(.title3.weight(.semibold))
                    Text(asset.date.formatted(Self.timeStyle)).foregroundStyle(.secondary)
                }
                if let onDate {
                    Button(action: onDate) { when.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help("Adjust Date and Time…")
                } else {
                    when
                }
                if let detail {
                    if onDescribe != nil {
                        TextField("Add a Description", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...8)
                            .focused($editing)
                            .onSubmit { editing = false }
                    } else if let text = detail.exifInfo?.description, !text.isEmpty {
                        Text(text).textSelection(.enabled)
                    }
                    if onRate != nil || (detail.exifInfo?.rating ?? 0) > 0 {
                        Stars(rating: detail.exifInfo?.rating, onRate: onRate)
                    }
                    let exif = detail.exifInfo
                    Row(symbol: asset.isVideo ? "video" : "photo", title: detail.originalFileName, lines: [fileLine(exif)])
                    if let camera = camera(exif) {
                        Row(symbol: "camera", title: camera, lines: [exif?.lensModel])
                        let settings = exposure(exif)
                        if !settings.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(settings, id: \.self) { Chip(text: $0) }
                            }
                        }
                    }
                    if let exif, let place = place(exif) {
                        Row(symbol: "mappin.and.ellipse", title: place, lines: [])
                    }
                    if let lat = exif?.latitude, let lon = exif?.longitude {
                        PlaceMap(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), name: place(exif!))
                            .id("\(asset.id)\(lat)\(lon)")
                    }
                    if let onPlace {
                        Button(exif?.latitude == nil ? "Add Location…" : "Change Location…", action: onPlace)
                            .linkStyle()
                    }
                    if onAddTag != nil || !(detail.tags ?? []).isEmpty {
                        Tags(tags: detail.tags ?? [], onAdd: onAddTag, onRemove: onUntag)
                    }
                    if let people = detail.people, !people.isEmpty {
                        People(people: people, onPerson: onPerson, onChange: onChangePerson)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: detail?.exifInfo?.description, initial: true) { if !editing { draft = $1 ?? "" } }
        .onChange(of: editing) {
            typing = editing
            if !editing, let detail, draft != detail.exifInfo?.description ?? "" { onDescribe?(draft) } // saved when the field is left
        }
        .onDisappear { typing = false }
    }

    /// 1–5 stars; clicking the current number of stars clears them.
    private struct Stars: View {
        let rating: Int?
        let onRate: ((Int?) -> Void)?

        var body: some View {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Button { onRate?(rating == n ? nil : n) } label: {
                        Image(systemName: n <= (rating ?? 0) ? "star.fill" : "star")
                            .foregroundStyle(n <= (rating ?? 0) ? Color.yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(onRate == nil)
                    .accessibilityLabel(rating == n ? "Clear Rating" : "\(n) Stars")
                    .help(rating == n ? "Clear Rating" : "\(n) Stars")
                }
            }
        }
    }

    private func fileLine(_ exif: AssetDetail.Exif?) -> String? {
        var parts: [String] = []
        if let w = exif?.exifImageWidth, let h = exif?.exifImageHeight { parts.append("\(Int(w)) × \(Int(h))") }
        if let w = exif?.exifImageWidth, let h = exif?.exifImageHeight, w * h >= 1_000_000 {
            parts.append((w * h / 1_000_000).formatted(.number.precision(.fractionLength(0))) + " MP")
        }
        if let bytes = exif?.fileSizeInByte { parts.append(Int64(bytes).formatted(.byteCount(style: .file))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Apple iPhone 15 Pro", without repeating a make the model already starts with.
    private func camera(_ exif: AssetDetail.Exif?) -> String? {
        let make = exif?.make ?? "", model = exif?.model ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        return make.isEmpty || model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
    }

    private func exposure(_ exif: AssetDetail.Exif?) -> [String] {
        guard let exif else { return [] }
        var out: [String] = []
        if let f = exif.fNumber { out.append("ƒ/" + f.formatted(.number.precision(.fractionLength(0...1)))) }
        if let t = exif.exposureTime, !t.isEmpty { out.append(t + " s") }
        if let mm = exif.focalLength { out.append(mm.formatted(.number.precision(.fractionLength(0...1))) + " mm") }
        if let iso = exif.iso { out.append("ISO \(Int(iso))") }
        return out
    }

    private func place(_ exif: AssetDetail.Exif) -> String? {
        var parts: [String] = []
        for part in [exif.city, exif.state, exif.country] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) } // a city that is also its state shows once
        }
        return parts.isEmpty ? nil : parts.joined(separator: String(localized: "place.separator", defaultValue: ", ",
                                                                         comment: "Between city, state and country"))
    }

    private struct Row: View {
        let symbol: String
        let title: String
        let lines: [String?]

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).textSelection(.enabled)
                    ForEach(lines.compactMap { $0 }, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private struct Chip: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .fixedSize()
        }
    }

    /// A small map; click to open the place in Maps.
    private struct PlaceMap: View {
        let coordinate: CLLocationCoordinate2D
        let name: String?

        var body: some View {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)),
                interactionModes: []) {
                Marker(name ?? "", coordinate: coordinate)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
                item.name = name
                item.openInMaps()
            }
            .help("Open in Maps")
        }
    }

    /// The photo's tags; ✕ takes one off.
    private struct Tags: View {
        let tags: [Tag]
        let onAdd: (() -> Void)?
        let onRemove: ((Tag) -> Void)?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label("Tags", systemImage: "tag").foregroundStyle(.secondary)
                ForEach(tags) { tag in
                    HStack {
                        Text(tag.value)
                        Spacer()
                        if let onRemove {
                            Button { onRemove(tag) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain)
                                .help("Remove Tag")
                        }
                    }
                }
                if let onAdd { Button("Add Tag…", action: onAdd).linkStyle() }
            }
        }
    }

    /// Everyone in the photo, named or not; click one for their photos.
    private struct People: View {
        @Environment(Library.self) private var library
        let people: [Person]
        let onPerson: (Person) -> Void
        let onChange: ((Person) -> Void)?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label("People", systemImage: "person.2").foregroundStyle(.secondary)
                ForEach(people) { person in
                    Button { onPerson(person) } label: {
                        HStack(spacing: 8) {
                            Thumb(id: person.id, store: library.faces)
                                .frame(width: 26, height: 26)
                                .clipShape(Circle())
                            Text(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show Their Photos")
                    .contextMenu { if let onChange { Button("Change Person…") { onChange(person) } } }
                }
            }
        }
    }
}

/// The people in the photo as faces over its bottom left corner; click one for their photos.
struct FaceRow: View {
    @Environment(Library.self) private var library
    let people: [Person]
    let onPerson: (Person) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(people) { person in
                    Button { onPerson(person) } label: {
                        HStack(spacing: 6) {
                            Thumb(id: person.id, store: library.faces)
                                .frame(width: 24, height: 24)
                                .clipShape(Circle())
                            if !person.name.isEmpty { Text(person.name).lineLimit(1) }
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, person.name.isEmpty ? 4 : 10)
                        .padding(.vertical, 4)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .help(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A button that looks like a link: the Mac's link style, plain tinted text elsewhere.
    func linkStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}
