import SwiftUI

/// The results of `query` in the usual grid, searched again after each change.
struct SearchResults: View {
    @Environment(Library.self) private var library
    let query: String
    @State private var assets: [Asset]?
    @State private var loads = 0
    @State private var error: String?

    var body: some View {
        TimelineBrowser(title: String(localized: "Search"), subtitle: assets.map { String(localized: "\($0.count) items") } ?? "",
                        assets: assets ?? [], revision: loads, context: .search)
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                           description: Text("Find what’s in the picture, like “beach at sunset”, or a file name, description or text in the picture."))
                } else if let error {
                    ContentUnavailableView("Can’t Search", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if assets == nil {
                    ProgressView()
                } else if assets?.isEmpty == true {
                    ContentUnavailableView.search(text: query)
                }
            }
            .task(id: "\(query)|\(library.edits)") { await search() }
    }

    private func search() async {
        guard let api = library.api, !query.isEmpty else { // cleared: the grid empties too (it regroups on `loads`)
            if assets != nil {
                assets = nil
                loads += 1
            }
            return
        }
        if error != nil { assets = nil } // a new try: the spinner, not the old error
        error = nil
        do {
            let found = try await api.search(query)
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
