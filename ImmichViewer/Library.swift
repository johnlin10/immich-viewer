import AppKit
import AVFoundation
import Observation

/// Connection settings, the asset list and the thumbnail cache.
@MainActor @Observable
final class Library {
    var serverURL = UserDefaults.standard.string(forKey: "server") ?? "http://localhost:2283"
    private(set) var api: ImmichAPI?
    private(set) var assets: [Asset] = []
    private(set) var revision = 0
    private(set) var status = ""
    private(set) var syncing = false
    private(set) var people: [Person] = []
    private(set) var albums: [Album] = []
    /// Why people or albums couldn't be loaded (for example a key without `person.read`).
    private(set) var collectionsError: String?
    let thumbs: ThumbnailStore
    /// Face crops for the people page.
    let faces: ThumbnailStore

    // ponytail: list and thumbnails are not keyed by server; clear ~/Library/Caches/ImmichViewer if you switch servers
    private let listFile: URL

    init() {
        let env = ProcessInfo.processInfo.environment
        var key = Keychain.load()
        var folder = "ImmichViewer"
        #if DEBUG
        // Testing from Xcode (Edit Scheme > Run > Environment Variables) without touching your real setup:
        // IMMICH_API_KEY skips the keychain, IMMICH_SERVER overrides the address, and
        // IMMICH_VIEWER_PROFILE keeps the list and thumbnails in separate folders.
        if let value = env["IMMICH_API_KEY"] { key = value }
        if let value = env["IMMICH_SERVER"] { serverURL = value }
        if let value = env["IMMICH_VIEWER_PROFILE"] { folder += "-" + value }
        #endif
        thumbs = ThumbnailStore(dir: URL.cachesDirectory.appending(path: "\(folder)/thumbnails", directoryHint: .isDirectory))
        faces = ThumbnailStore(dir: URL.cachesDirectory.appending(path: "\(folder)/faces", directoryHint: .isDirectory)) {
            try await $0.get("people/\($1)/thumbnail")
        }
        listFile = URL.applicationSupportDirectory.appending(path: "\(folder)/assets.json")

        if let key, let url = URL(string: serverURL) { api = ImmichAPI(server: url, key: key) }
        // last known list, so the grid shows instantly while the new list loads
        if let data = try? Data(contentsOf: listFile), let list = try? JSONDecoder().decode([Asset].self, from: data) {
            assets = list
            revision += 1
            status = "\(list.count.formatted()) 項"
        }
    }

    func connect(server: String, key: String) {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)) else { return }
        serverURL = url.absoluteString
        UserDefaults.standard.set(serverURL, forKey: "server")
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(key)
        api = ImmichAPI(server: url, key: key)
        Task { await refresh() }
    }

    /// Reloads the asset list, then downloads any thumbnails not cached yet.
    func refresh() async {
        guard let api, !syncing else { return }
        syncing = true
        defer { syncing = false }
        status = "正在同步清單…"
        let list: [Asset]
        do {
            list = try await api.timeline()
        } catch {
            status = "同步失敗：\(error.localizedDescription)"
            return
        }
        assets = list
        revision += 1
        try? FileManager.default.createDirectory(at: listFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: listFile, options: .atomic)
        await loadCollections()

        await thumbs.downloadMissing(list.map(\.id), api: api) { done, total, failed in
            let fails = failed > 0 ? "，\(failed) 張失敗" : ""
            self.status = done < total
                ? "正在下載縮圖 \(done.formatted()) / \(total.formatted())\(fails)"
                : "\(list.count.formatted()) 項\(fails)"
        }
    }

    /// People and albums; a failure only shows on those pages, the timeline keeps working.
    func loadCollections() async {
        guard let api else { return }
        do {
            async let people = api.people()
            async let albums = api.albums()
            (self.people, self.albums) = try await (people, albums)
            collectionsError = nil
        } catch {
            collectionsError = error.localizedDescription
        }
    }

    /// One person's or album's photos, fetched each time the page opens (not cached).
    func assets(_ filter: [String: String]) async throws -> [Asset] {
        guard let api else { return [] }
        return try await api.timeline(filter)
    }

    /// The large (~1440 px) version for the single-photo view. Not cached on disk.
    func preview(_ asset: Asset) async -> NSImage? {
        guard let api, let data = try? await api.thumbnail(asset.id, size: "preview") else { return nil }
        return NSImage(data: data)
    }

    func detail(_ asset: Asset) async -> AssetDetail? { try? await api?.detail(asset.id) }

    /// Whether the key has `asset.download`; nil until the first try.
    private(set) var canDownload: Bool?

    /// The original file if the key may download it, else the large preview. For zooming, copying and dragging out.
    func full(_ asset: Asset) async -> Data? {
        guard let api else { return nil }
        if canDownload != false {
            do {
                let data = try await api.original(asset.id)
                canDownload = true
                return data
            } catch let error as ImmichAPI.HTTPError where error.status == 401 || error.status == 403 {
                canDownload = false
            } catch {}
        }
        return try? await api.thumbnail(asset.id, size: "preview")
    }

    /// Streams a video from the server (the transcoded version, as the web UI plays it).
    func player(for asset: Asset) -> AVPlayer? {
        guard let api else { return nil }
        let url = api.server.appending(path: "api/assets/\(asset.id)/video/playback")
        // ponytail: header option key is undocumented but long-standing; a signed URL would replace it if it ever breaks
        let video = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["x-api-key": api.key]])
        return AVPlayer(playerItem: AVPlayerItem(asset: video))
    }

    func openInBrowser(_ asset: Asset) {
        guard let api else { return }
        NSWorkspace.shared.open(api.server.appending(path: "photos/\(asset.id)"))
    }
}
