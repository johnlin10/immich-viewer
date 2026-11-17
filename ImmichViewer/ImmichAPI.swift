import Foundation
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
    func download(_ id: String) async throws -> (file: URL, name: String) {
        let (file, response) = try await URLSession.shared.download(for: request("GET", "assets/\(id)/original"))
        do {
            try Self.verify(response, (try? Data(contentsOf: file)) ?? Data())
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return (file, response.suggestedFilename ?? id)
    }

    /// Uploads a file as a new asset. Returns its id (the existing one if the server already has the file).
    /// The multipart body is written to a temporary file first, so a large video never has to fit in memory.
    func upload(_ file: URL) async throws -> String {
        let values = try file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let boundary = UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appending(path: "ImmichViewer-upload-\(boundary)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let out = try FileHandle(forWritingTo: body)
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        let date = ISO8601DateFormatter()
        var head = ""
        for (field, value) in [("fileCreatedAt", date.string(from: values.creationDate ?? .now)),
                               ("fileModifiedAt", date.string(from: values.contentModificationDate ?? .now)),
                               ("filename", name)] {
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
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        try Self.verify(response, data)
        struct Result: Decodable { let id: String }
        return try JSONDecoder().decode(Result.self, from: data).id
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
                                     isFavorite: c.isFavorite?[i] == true)
                    }
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }
        }
        return assets.sorted { $0.date > $1.date }
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

    /// Own albums and albums shared with you, most recent first.
    func albums() async throws -> [Album] {
        let albums = try JSONDecoder().decode([Album].self, from: await get("albums"))
        return albums.sorted { ($0.endDate ?? "") > ($1.endDate ?? "") }
    }
}

struct Person: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    /// yyyy-MM-dd
    var birthDate: String?
    /// Their faces in one photo, in an asset's details only.
    var faces: [Face]?

    struct Face: Codable, Hashable, Sendable { let id: String }
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

/// The API key lives in the login keychain, never in a plain file.
enum Keychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "ImmichViewer"]

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
