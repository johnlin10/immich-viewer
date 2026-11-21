import AVFoundation
import Foundation
import ImageIO
import Security

/// The Immich endpoints the app uses.
/// Browsing needs `asset.read`, `asset.view`, `person.read` and `album.read`; `asset.download` is optional (originals).
/// Editing needs `asset.update`, `asset.delete`, `asset.upload`, `tag.*`, `person.merge`, `face.update`, `person.update`, `album.create`, `album.update`, `album.delete`,
/// `albumAsset.create` and `albumAsset.delete`; without them the change fails with the server's message.
struct ImmichAPI: Sendable {
    let server: URL
    let key: String

    struct HTTPError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "HTTP \(status) \(message)" }
    }

    /// What people type into the address field, as the server's base URL: `nas.local:2283`, `http://192.168.1.20:2283/`
    /// and `https://photos.example.com/api` all work. Nil if there's no host.
    static func address(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !["http://", "https://"].contains(where: { s.lowercased().hasPrefix($0) }) { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/api") { s.removeLast(4) }
        guard let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }

    /// The folder name for a server's cached list and thumbnails: `http://nas.local:2283` → `nas-local-2283`.
    static func folder(_ server: String) -> String {
        let rest = server.range(of: "://").map { String(server[$0.upperBound...]) } ?? server
        return rest.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// True once the server answers. Needs no key, so it also works before connecting.
    static func ping(_ server: URL) async -> Bool {
        let request = URLRequest(url: server.appending(path: "api/server/ping"), timeoutInterval: 5)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Tries the address and key with the first call a sync makes. Nil if they work, else why not, for the Connection settings.
    func check() async -> String? {
        do {
            _ = try await get("timeline/buckets", ["visibility": "timeline"])
            return nil
        } catch let error as HTTPError {
            return switch error.status {
            case 401: String(localized: "The server didn’t accept this API key.")
            case 404: String(localized: "Something answered at \(server.absoluteString), but it isn’t an Immich server. Check the port.")
            default: error.localizedDescription // 403 names the missing permission
            }
        } catch {
            return String(localized: "Couldn’t reach \(server.absoluteString): \(error.localizedDescription) Check the address and port, and that the server is running. For a server on another computer, also check that Immich Viewer is on in System Settings > Privacy & Security > Local Network.")
        }
    }

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        try await send("GET", path, query: query)
    }

    /// A change: `json` is the request body (NSNull for null). Returns the response body.
    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws -> Data {
        var request = request(method, path, query: query)
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.verify(response, data)
        return data
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:]) -> URLRequest {
        var url = server.appending(path: "api/" + path)
        // sorted, so the same request always has the same URL (and cache entry)
        if !query.isEmpty { url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        return request
    }

    private static func verify(_ response: URLResponse, _ body: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Body: Decodable { let message: String? }
            throw HTTPError(status: status, message: (try? JSONDecoder().decode(Body.self, from: body))?.message ?? "")
        }
    }

    /// The original file, into a temporary file the caller moves, and its name on the server.
    /// Its bytes count as one unit of `progress`, if given; cancelling that cancels the download.
    func download(_ id: String, progress: Progress? = nil) async throws -> (file: URL, name: String) {
        let (file, response) = try await URLSession.shared.download(for: request("GET", "assets/\(id)/original"),
                                                                    delegate: progress.map(ProgressLink.init))
        do {
            try Self.verify(response, (try? Data(contentsOf: file)) ?? Data())
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return (file, response.suggestedFilename ?? id)
    }

    /// Makes a download's or upload's own progress part of `parent`.
    private final class ProgressLink: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let parent: Progress
        init(_ parent: Progress) { self.parent = parent }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            parent.addChild(task.progress, withPendingUnitCount: 1)
        }
    }

    /// Uploads a file as a new asset. Returns its id (the existing one if the server already has the file).
    /// The multipart body is written to a temporary file first, so a large video never has to fit in memory.
    /// Its bytes count as one unit of `progress`, if given; cancelling that cancels the upload.
    func upload(_ upload: UploadFile, livePhotoVideoId: String? = nil, progress: Progress? = nil) async throws -> String {
        let file = upload.url
        let values = try file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        // without a date of its own (EXIF, a video's creation date) the server dates it by this. A copied file's creation
        // date can be when it was copied, while copies usually keep the modification date: the earlier of the two
        let fileDates = [values.creationDate, values.contentModificationDate].compactMap { $0 }
        let created = upload.created ?? fileDates.min() ?? .now
        let boundary = UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appending(path: "ImmichViewer-upload-\(boundary)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let out = try FileHandle(forWritingTo: body)
        let name = (upload.name ?? file.lastPathComponent).replacingOccurrences(of: "\"", with: "'")
        let date = ISO8601DateFormatter()
        var head = ""
        var fields = [("fileCreatedAt", date.string(from: created)),
                      ("fileModifiedAt", date.string(from: upload.modified ?? values.contentModificationDate ?? created)),
                      ("filename", name)]
        if upload.favorite { fields.append(("isFavorite", "true")) }
        if let livePhotoVideoId { fields.append(("livePhotoVideoId", livePhotoVideoId)) }
        for (field, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n"
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(name)\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        try out.write(contentsOf: Data(head.utf8))
        let input = try FileHandle(forReadingFrom: file)
        while let chunk = try input.read(upToCount: 1 << 22), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try input.close()
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var request = request("POST", "assets")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body,
                                                                  delegate: progress.map(ProgressLink.init))
        try Self.verify(response, data)
        struct Result: Decodable { let id: String; let status: String? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        // a file without a date of its own (an image saved from the web) would be dated by the bare `fileCreatedAt`,
        // which Immich shows as UTC (8 hours early in Taiwan): give it the date again with this device's time zone,
        // as editing the date does (the server writes it to the .xmp and reads it back)
        if result.status != "duplicate", !upload.liveVideo, await !Self.hasOwnDate(file) {
            let local = ISO8601DateFormatter()
            local.timeZone = .current
            try await send("PUT", "assets/\(result.id)", json: ["dateTimeOriginal": local.string(from: created)])
        }
        return result.id
    }

    /// Whether the file says when it was taken, where Immich looks: EXIF, IPTC, XMP, a video's creation date.
    /// Unsure counts as no: setting the date again with the same moment does no harm.
    static func hasOwnDate(_ file: URL) async -> Bool {
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            if exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifDateTimeDigitized] != nil
                || iptc[kCGImagePropertyIPTCDateCreated] != nil { return true }
            guard let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
            return ["exif:DateTimeOriginal", "xmp:CreateDate", "photoshop:DateCreated"]
                .contains { CGImageMetadataCopyTagWithPath(xmp, nil, $0 as CFString) != nil }
        }
        return (try? await AVURLAsset(url: file).load(.creationDate)) != nil
    }

    /// `size`: "thumbnail" (~250 px, cached on disk) or "preview" (~1440 px, for the single-photo view).
    func thumbnail(_ id: String, size: String = "thumbnail") async throws -> Data {
        try await get("assets/\(id)/thumbnail", ["size": size, "edited": "true"]) // rotated, if it was
    }

    /// File name, camera settings, place and people of one asset.
    func detail(_ id: String) async throws -> AssetDetail {
        try JSONDecoder().decode(AssetDetail.self, from: await get("assets/\(id)"))
    }

    /// The file as uploaded, rotated if it was. Needs `asset.download`.
    func original(_ id: String) async throws -> Data { try await get("assets/\(id)/original", ["edited": "true"]) }

    /// Drops the HTTP cache's copies of an asset's pictures. Immich lets them be cached for a day,
    /// so after a rotate the old ones would keep coming back.
    func forgetCached(_ id: String) {
        for size in ["thumbnail", "preview"] {
            URLCache.shared.removeCachedResponse(for: request("GET", "assets/\(id)/thumbnail", query: ["size": size, "edited": "true"]))
        }
        URLCache.shared.removeCachedResponse(for: request("GET", "assets/\(id)/original", query: ["edited": "true"]))
    }

    /// Every asset matching `filter`, newest first. The default is the main timeline (not archived, hidden or locked);
    /// `personId` or `albumId` narrow it the way the web UI's person and album pages do.
    func timeline(_ filter: [String: String] = ["visibility": "timeline"]) async throws -> [Asset] {
        struct Bucket: Decodable { let timeBucket: String }
        struct Columns: Decodable {
            let id: [String]
            let fileCreatedAt: [String]
            let localOffsetHours: [Double]
            let isImage: [Bool]
            let isFavorite: [Bool]?
            let livePhotoVideoId: [String?]?
        }
        let buckets = try JSONDecoder().decode([Bucket].self, from: await get("timeline/buckets", filter))
        let assets = try await withThrowingTaskGroup(of: [Asset].self) { group in
            for bucket in buckets {
                group.addTask {
                    let data = try await get("timeline/bucket", filter.merging(["timeBucket": bucket.timeBucket]) { $1 })
                    let c = try JSONDecoder().decode(Columns.self, from: data)
                    let parser = UTCDateParser()
                    return c.id.indices.compactMap { i in
                        guard let utc = parser.date(c.fileCreatedAt[i]) else { return nil }
                        // local wall-clock time, kept in UTC like the web timeline does
                        return Asset(id: c.id[i], date: utc.addingTimeInterval(c.localOffsetHours[i] * 3600), isVideo: !c.isImage[i],
                                     isFavorite: c.isFavorite?[i] == true, isLive: (c.livePhotoVideoId?[i] ?? nil) != nil)
                    }
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }
        }
        return assets.sorted { $0.date > $1.date }
    }

    /// One search for `query`: photos whose file name, description or text in the picture contains it first, newest first;
    /// then what smart search finds, best match first.
    func search(_ query: String) async throws -> [Asset] {
        async let text = textSearch(query)
        async let smart = try? smartSearch(query) // a server without machine learning: the text matches alone
        let found = try await text
        let ids = Set(found.map(\.id))
        return found + (await smart ?? []).filter { !ids.contains($0.id) }
    }

    /// Smart search: photos showing what `query` describes, best match first, as Immich's machine learning ranks them.
    /// It ranks every photo, so only the best `size` come back.
    private func smartSearch(_ query: String, size: Int = 500) async throws -> [Asset] {
        try await searchPage("smart", ["query": query, "size": size]).assets
    }

    /// Photos whose file name, description or text in the picture contains `query`, newest first.
    private func textSearch(_ query: String) async throws -> [Asset] {
        try await withThrowingTaskGroup(of: [Asset].self) { group in
            for field in ["originalFileName", "description", "ocr"] {
                group.addTask {
                    var all: [Asset] = []
                    for page in 1...10 { // ponytail: 10,000 per field at most
                        let p = try await searchPage("metadata", [field: query, "size": 1000, "page": page])
                        all += p.assets
                        if !p.more { break }
                    }
                    return all
                }
            }
            var seen = Set<String>()
            return try await group.reduce(into: []) { $0 += $1 }.filter { seen.insert($0.id).inserted }.sorted { $0.date > $1.date }
        }
    }

    private func searchPage(_ kind: String, _ body: [String: Any]) async throws -> (assets: [Asset], more: Bool) {
        struct Item: Decodable {
            let id, type, localDateTime: String
            let isFavorite: Bool?
            let livePhotoVideoId: String?
        }
        struct Response: Decodable {
            struct Page: Decodable { let items: [Item]; let nextPage: String? }
            let assets: Page
        }
        let page = try JSONDecoder().decode(Response.self, from: await send("POST", "search/\(kind)", json: body)).assets
        let parser = UTCDateParser()
        let assets = page.items.compactMap { item in
            // localDateTime: the local wall-clock time kept in UTC, like the timeline's
            parser.date(item.localDateTime).map {
                Asset(id: item.id, date: $0, isVideo: item.type == "VIDEO", isFavorite: item.isFavorite == true,
                      isLive: item.livePhotoVideoId != nil)
            }
        }
        return (assets, page.nextPage != nil)
    }

    /// People that aren't hidden, in Immich's order (named and most photographed first).
    func people() async throws -> [Person] {
        struct Page: Decodable {
            let people: [Person]
            let hasNextPage: Bool?
        }
        var all: [Person] = []
        for page in 1... {
            let data = try await get("people", ["withHidden": "false", "page": "\(page)", "size": "500"])
            let p = try JSONDecoder().decode(Page.self, from: data)
            all += p.people
            if p.hasNextPage != true { break }
        }
        return all
    }

    /// Whether deleting moves to the trash. With the trash turned off on the server, deleting is permanent.
    func trashEnabled() async throws -> Bool {
        struct Features: Decodable { let trash: Bool }
        return try JSONDecoder().decode(Features.self, from: await get("server/features")).trash
    }

    func tags() async throws -> [Tag] {
        try JSONDecoder().decode([Tag].self, from: await get("tags")).sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    /// Ids of the albums you own, so the rest are shared with you. Nil if the server can't tell
    /// (one without the `isOwned` filter answers both questions with every album).
    func ownedAlbumIDs() async throws -> Set<String>? {
        struct Item: Decodable { let id: String }
        async let owned = get("albums", ["isOwned": "true"])
        async let others = get("albums", ["isOwned": "false"])
        let mine = Set(try JSONDecoder().decode([Item].self, from: await owned).map(\.id))
        let theirs = Set(try JSONDecoder().decode([Item].self, from: await others).map(\.id))
        return mine.isDisjoint(with: theirs) ? mine : nil
    }

    /// Own albums and albums shared with you, most recent first.
    func albums() async throws -> [Album] {
        let albums = try JSONDecoder().decode([Album].self, from: await get("albums"))
        return albums.sorted { ($0.endDate ?? "") > ($1.endDate ?? "") }
    }
}

/// A file to upload, with what the server should keep that the file itself may not say.
struct UploadFile: Sendable {
    var url: URL
    /// The name on the server; the file's own if nil.
    var name: String?
    /// For a file without a date in its metadata; the file's dates if nil.
    var created: Date?
    var modified: Date?
    var favorite = false
    /// A Live Photo's video: uploaded first, then linked to the file after it, its still.
    var liveVideo = false
    /// A copy made for the upload, deleted once it's done.
    var temporary = false
}

struct Person: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    /// yyyy-MM-dd
    var birthDate: String?
    /// Their faces in one photo, in an asset's details only.
    var faces: [Face]?

    struct Face: Codable, Hashable, Sendable { let id: String }

    /// The birthday as a local date and the age in whole years on `now`; nil without one.
    func birthday(on now: Date = .now) -> (date: Date, age: Int)? {
        let parts = (birthDate ?? "").prefix(10).split(separator: "-").compactMap { Int($0) }
        let calendar = Calendar(identifier: .gregorian) // also where the system shows another calendar
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let age = calendar.dateComponents([.year], from: date, to: now).year else { return nil }
        return (date, max(age, 0))
    }
}

/// The People page's filter menu: Named and Unnamed are either-or (neither or both: everyone); Has Birthday narrows further.
struct PeopleFilter: Equatable {
    var named = false
    var unnamed = false
    var birthday = false

    var isActive: Bool { named || unnamed || birthday }

    func apply(_ people: [Person]) -> [Person] {
        people.filter { person in
            (named == unnamed || (person.name.isEmpty ? unnamed : named)) && (!birthday || person.birthday() != nil)
        }
    }
}

/// The People page's sort menu. `standard` keeps the server's order (favorites, then named, then most photographed).
enum PeopleSort: String, CaseIterable {
    case standard, name, youngest, oldest

    /// Unnamed people, and people without a birthday when sorting by age, go last in the server's order.
    func apply(_ people: [Person]) -> [Person] {
        func ordered(_ key: (Person) -> String?, _ before: (String, String) -> Bool) -> [Person] {
            people.enumerated().sorted { a, b in
                switch (key(a.element), key(b.element)) {
                case let (x?, y?) where x != y: before(x, y)
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }.map(\.element)
        }
        let name = { (p: Person) in p.name.isEmpty ? nil : p.name }
        let born = { (p: Person) in p.birthDate.map { String($0.prefix(10)) }.flatMap { $0.isEmpty ? nil : $0 } }
        return switch self {
        case .standard: people
        case .name: ordered(name) { $0.localizedStandardCompare($1) == .orderedAscending }
        case .youngest: ordered(born, >)
        case .oldest: ordered(born, <)
        }
    }
}

struct Tag: Codable, Identifiable, Hashable, Sendable {
    let id: String
    /// The full path, like "Trips/Japan".
    let value: String
}

struct AssetDetail: Decodable, Sendable {
    let originalFileName: String
    var isFavorite: Bool?
    var exifInfo: Exif?
    let people: [Person]?
    var tags: [Tag]?
    /// A Live Photo's (or motion photo's) moving part, a hidden video asset.
    var livePhotoVideoId: String?

    /// Numbers are Doubles so ints and floats both decode.
    struct Exif: Decodable, Sendable {
        var make, model, lensModel, exposureTime, city, state, country, description: String?
        var fNumber, focalLength, iso, exifImageWidth, exifImageHeight, fileSizeInByte, latitude, longitude: Double?
        /// 1–5 stars, -1 rejected, nil unrated.
        var rating: Int?
    }
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var albumName: String
    var description: String?
    var albumThumbnailAssetId: String?
    var assetCount: Int
    var endDate: String?
}

/// The Albums page's sort menu. `recent` keeps the newest photos first, as loaded.
enum AlbumSort: String, CaseIterable {
    case recent, name, count

    func apply(_ albums: [Album]) -> [Album] {
        switch self {
        case .recent: albums
        case .name: albums.sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
        case .count: albums.sorted { $0.assetCount > $1.assetCount }
        }
    }
}


/// API keys live in the login keychain, never in a plain file: one per server, under its address.
enum Keychain {
    /// `server` nil: any key, for moving the single key from before several servers.
    private static func query(_ server: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ImmichViewer"]
        if let server { q[kSecAttrAccount as String] = server }
        return q
    }

    static func load(_ server: String?) -> String? {
        var q = query(server)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, _ server: String) {
        delete(server)
        var q = query(server)
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    /// `server` nil deletes every key.
    static func delete(_ server: String?) { SecItemDelete(query(server) as CFDictionary) }
}
