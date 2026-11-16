import Foundation
import Security

/// The few Immich endpoints the viewer needs.
/// The API key needs `asset.read`, `asset.view`, `person.read` and `album.read`; `asset.download` is optional (originals).
struct ImmichAPI: Sendable {
    let server: URL
    let key: String

    struct HTTPError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "HTTP \(status) \(message)" }
    }

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        var url = server.appending(path: "api/" + path)
        if !query.isEmpty { url.append(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) }) }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct Body: Decodable { let message: String? }
            throw HTTPError(status: status, message: (try? JSONDecoder().decode(Body.self, from: data))?.message ?? "")
        }
        return data
    }

    /// `size`: "thumbnail" (~250 px, cached on disk) or "preview" (~1440 px, for the single-photo view).
    func thumbnail(_ id: String, size: String = "thumbnail") async throws -> Data {
        try await get("assets/\(id)/thumbnail", ["size": size])
    }

    /// File name, camera settings, place and people of one asset.
    func detail(_ id: String) async throws -> AssetDetail {
        try JSONDecoder().decode(AssetDetail.self, from: await get("assets/\(id)"))
    }

    /// The file as uploaded. Needs `asset.download`.
    func original(_ id: String) async throws -> Data { try await get("assets/\(id)/original") }

    /// Every asset matching `filter`, newest first. The default is the main timeline (not archived, hidden or locked);
    /// `personId` or `albumId` narrow it the way the web UI's person and album pages do.
    func timeline(_ filter: [String: String] = ["visibility": "timeline"]) async throws -> [Asset] {
        struct Bucket: Decodable { let timeBucket: String }
        struct Columns: Decodable {
            let id: [String]
            let fileCreatedAt: [String]
            let localOffsetHours: [Double]
            let isImage: [Bool]
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
                        return Asset(id: c.id[i], date: utc.addingTimeInterval(c.localOffsetHours[i] * 3600), isVideo: !c.isImage[i])
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

    /// Own albums and albums shared with you, most recent first.
    func albums() async throws -> [Album] {
        let albums = try JSONDecoder().decode([Album].self, from: await get("albums"))
        return albums.sorted { ($0.endDate ?? "") > ($1.endDate ?? "") }
    }
}

struct Person: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct AssetDetail: Decodable, Sendable {
    let originalFileName: String
    let exifInfo: Exif?
    let people: [Person]?

    /// Numbers are Doubles so ints and floats both decode.
    struct Exif: Decodable, Sendable {
        let make, model, lensModel, exposureTime, city, state, country, description: String?
        let fNumber, focalLength, iso, exifImageWidth, exifImageHeight, fileSizeInByte, latitude, longitude: Double?
    }
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let albumName: String
    let albumThumbnailAssetId: String?
    let assetCount: Int
    let endDate: String?
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
