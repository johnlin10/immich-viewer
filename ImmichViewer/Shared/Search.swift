import SwiftUI

/// The results of `query` and the filters in the usual grid, searched again after each change.
struct SearchResults: View {
    @Environment(Library.self) private var library
    let query: String
    @State private var filter = SearchFilter()
    @State private var filtersShown = false
    @State private var assets: [Asset]?
    @State private var loads = 0
    @State private var error: String?

    var body: some View {
        TimelineBrowser(title: String(localized: "Search"), subtitle: assets.map { String(localized: "\($0.count) items") } ?? "",
                        assets: assets ?? [], revision: loads, context: .search)
            .overlay {
                if query.isEmpty, !filter.isActive {
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                           description: Text("Find what’s in the picture, like “beach at sunset”, or a file name, description or text in the picture."))
                } else if let error {
                    ContentUnavailableView("Can’t Search", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if assets == nil {
                    ProgressView()
                } else if assets?.isEmpty == true {
                    if query.isEmpty {
                        ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try other filters."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // not the ⋯ menu's Filter: that one narrows the results shown, this one what the server is asked for
                    // tinted glass when on: the glass toolbar ignores symbol fill and tint
                    if filter.isActive {
                        filtersButton.buttonStyle(.glassProminent)
                    } else {
                        filtersButton
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $filtersShown) { // a popover's Form has no size of its own and collapses on iPad
                NavigationStack {
                    SearchFilterForm(filter: $filter)
                        .navigationTitle("Search Filters")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Clear Filters") { filter = SearchFilter() }.disabled(!filter.isActive)
                            }
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { filtersShown = false } }
                        }
                }
            }
            #endif
            .task(id: SearchKey(query: query, filter: filter, edits: library.edits)) { await search() }
    }

    private var filtersButton: some View {
        Button { filtersShown = true } label: { Label("Search Filters", systemImage: "slider.horizontal.3") }
            .help("Search Filters")
            #if os(macOS)
            .popover(isPresented: $filtersShown) {
                VStack(spacing: 0) {
                    SearchFilterForm(filter: $filter)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Clear Filters") { filter = SearchFilter() }.disabled(!filter.isActive)
                    }
                    .padding(10)
                }
                .frame(width: 340, height: 480)
            }
            #endif
    }

    private func search() async {
        guard let api = library.api, !query.isEmpty || filter.isActive else { // cleared: the grid empties too (it regroups on `loads`)
            if assets != nil {
                assets = nil
                loads += 1
            }
            return
        }
        if error != nil { assets = nil } // a new try: the spinner, not the old error
        error = nil
        do {
            let found = try await api.search(query, filter: filter)
            guard found != assets else { return } // unchanged: the grid stays put
            assets = found
            loads += 1
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What a search depends on: it runs again when any of it changes.
private struct SearchKey: Hashable {
    let query: String
    let filter: SearchFilter
    let edits: Int
}

/// The Search Filters popover (a sheet on iPhone and iPad). Changes apply at once.
struct SearchFilterForm: View {
    @Environment(Library.self) private var library
    @Binding var filter: SearchFilter
    @State private var countries: [String] = []
    @State private var states: [String] = []
    @State private var cities: [String] = []
    @State private var personQuery = ""

    private var chosen: [Person] { filter.people.compactMap { id in library.people.first { $0.id == id } } }
    private var addable: [Person] {
        let open = library.people.filter { !filter.people.contains($0.id) } // the server's order: most photographed first
        return personQuery.isEmpty ? open : open.filter { $0.name.localizedCaseInsensitiveContains(personQuery) }
    }

    var body: some View {
        Form {
            SwiftUI.Section("Place") {
                place("Country", $filter.country.onSet { _ in filter.state = nil; filter.city = nil }, countries)
                place("State", $filter.state.onSet { _ in filter.city = nil }, states).disabled(filter.country == nil)
                place("City", $filter.city, cities).disabled(filter.country == nil)
            }
            SwiftUI.Section("Date") {
                day("From", $filter.from)
                day("To", $filter.to)
            }
            SwiftUI.Section {
                ForEach(chosen) { person in
                    HStack(spacing: 8) {
                        Thumb(id: person.id, store: library.faces).frame(width: 28, height: 28).clipShape(Circle())
                        Text(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                            .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Remove", systemImage: "xmark.circle.fill") { filter.people.removeAll { $0 == person.id } }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                TextField("Search People", text: $personQuery)
                ForEach(addable) { person in
                    Button {
                        filter.people.append(person.id)
                        personQuery = ""
                    } label: {
                        HStack(spacing: 10) {
                            Thumb(id: person.id, store: library.faces).frame(width: 36, height: 36).clipShape(Circle())
                            Text(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if addable.isEmpty { Text("No Matches").foregroundStyle(.secondary) }
            } header: {
                Text("People")
            } footer: {
                Text("Photos with all of them.")
            }
        }
        .formStyle(.grouped)
        .task { countries = await names("country") }
        .task(id: filter.country) { states = filter.country == nil ? [] : await names("state", filter.country) }
        .task(id: [filter.country, filter.state]) { cities = filter.country == nil ? [] : await names("city", filter.country, filter.state) }
    }

    /// A failed load leaves just "Any", with no alert.
    private func names(_ type: String, _ country: String? = nil, _ state: String? = nil) async -> [String] {
        (try? await library.api?.places(type, country: country, state: state)) ?? []
    }

    private func place(_ title: LocalizedStringKey, _ selection: Binding<String?>, _ options: [String]) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(String?.none)
            ForEach(options, id: \.self) { Text($0).tag(String?.some($0)) }
        }
    }

    /// A switch with a day picker under it; on starts at today.
    @ViewBuilder
    private func day(_ title: LocalizedStringKey, _ date: Binding<Date?>) -> some View {
        Toggle(title, isOn: Binding(get: { date.wrappedValue != nil }, set: { date.wrappedValue = $0 ? .now : nil }))
        if let value = date.wrappedValue {
            DatePicker(title, selection: Binding(get: { value }, set: { date.wrappedValue = $0 }), displayedComponents: .date)
                .labelsHidden()
        }
    }
}

private extension Binding {
    /// The same binding that also runs `then` after each write.
    func onSet(_ then: @escaping (Value) -> Void) -> Binding {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; then($0) })
    }
}

#if os(macOS)
/// The Search page: the field in the toolbar, Return searches.
struct SearchPage: View {
    @State private var text = ""
    @State private var query = ""

    var body: some View {
        SearchResults(query: query)
            .searchable(text: $text, prompt: Text("Search your library"))
            .onSubmit(of: .search) { query = text.trimmingCharacters(in: .whitespaces) }
            .onChange(of: text) { if text.isEmpty { query = "" } }
    }
}
#endif
