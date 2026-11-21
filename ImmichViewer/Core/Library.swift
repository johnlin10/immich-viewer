#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import CoreLocation
import Observation

/// Connection settings, starting and stopping the server, the asset list and the thumbnail cache.
@MainActor @Observable
final class Library {
    var serverURL = UserDefaults.standard.string(forKey: "server") ?? "http://localhost:2283"
    private(set) var api: ImmichAPI?
    private(set) var assets: [Asset] = []
    private(set) var revision = 0
    private(set) var status = ""
    /// The download under way, for the progress panel; cancel it to stop. `transferStep` is the file it is on, from 1.
    private(set) var transfer: Progress?
    private(set) var transferStep = 0
    private(set) var syncing = false
    private(set) var people: [Person] = []
    private(set) var albums: [Album] = []
    private(set) var tags: [Tag] = []
    /// Ids of your own albums (the rest are shared with you); nil if the server can't tell.
    private(set) var ownedAlbums: Set<String>?
    /// Why people or albums couldn't be loaded (for example a key without `person.read`).
    private(set) var collectionsError: String?
    private(set) var thumbs: ThumbnailStore
    /// Face crops for the people page.
    private(set) var faces: ThumbnailStore
    /// Every server connected to, by address. Each keeps its own key, list and thumbnails.
    private(set) var servers = UserDefaults.standard.stringArray(forKey: "servers") ?? []

    private var listFile: URL
    /// "ImmichViewer", or "ImmichViewer-<profile>" in debug builds.
    private let base: String
    /// The running sync, so switching servers can stop it.
    private var syncTask: Task<Void, Never>?

    init() {
        let env = ProcessInfo.processInfo.environment
        var base = "ImmichViewer"
        var debugKey: String?
        var server = UserDefaults.standard.string(forKey: "server") ?? "http://localhost:2283"
        #if DEBUG
        // Testing from Xcode (Edit Scheme > Run > Environment Variables) without touching your real setup:
        // IMMICH_API_KEY skips the keychain, IMMICH_SERVER overrides the address, and
        // IMMICH_VIEWER_PROFILE keeps the list and thumbnails in separate folders.
        debugKey = env["IMMICH_API_KEY"]
        if let value = env["IMMICH_SERVER"] { server = value }
        if let value = env["IMMICH_VIEWER_PROFILE"] { base += "-" + value }
        #endif
        self.base = base
        (thumbs, faces, listFile) = Self.stores(base, server)
        serverURL = server
        if UserDefaults.standard.object(forKey: "servers") == nil { moveSingleServer() }
        moveSharedCommands()
        if let key = debugKey ?? Keychain.load(serverURL), let url = URL(string: serverURL) { api = ImmichAPI(server: url, key: key) }
        loadList()
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopServerAtQuit() }
        }
        #endif
    }

    private static func stores(_ base: String, _ server: String) -> (ThumbnailStore, ThumbnailStore, URL) {
        let folder = "\(base)/\(ImmichAPI.folder(server))"
        return (ThumbnailStore(dir: URL.cachesDirectory.appending(path: "\(folder)/thumbnails", directoryHint: .isDirectory)),
                ThumbnailStore(dir: URL.cachesDirectory.appending(path: "\(folder)/faces", directoryHint: .isDirectory)) {
                    try await $0.get("people/\($1)/thumbnail")
                },
                URL.applicationSupportDirectory.appending(path: "\(folder)/assets.json"))
    }

    /// Up to 0.6 there was one server: its key had no address and its files sat right in the base folder.
    /// Moves them to the current server's place, so nothing downloads again.
    private func moveSingleServer() {
        if let key = Keychain.load(nil) {
            let server = UserDefaults.standard.string(forKey: "server") ?? serverURL // the saved one, also when debugging another
            Keychain.delete(nil)
            Keychain.save(key, server)
            servers = [server]
        }
        UserDefaults.standard.set(servers, forKey: "servers")
        let old = [URL.cachesDirectory.appending(path: "\(base)/thumbnails"), URL.cachesDirectory.appending(path: "\(base)/faces"),
                   URL.applicationSupportDirectory.appending(path: "\(base)/assets.json")]
        for (from, to) in zip(old, [thumbs.dir, faces.dir, listFile]) where FileManager.default.fileExists(atPath: from.path) {
            try? FileManager.default.removeItem(at: to) // the stores just made it empty
            try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// Up to 0.6 the start and stop commands were shared; they belong to the first server (the one from before several servers).
    private func moveSharedCommands() {
        let defaults = UserDefaults.standard
        for name in Self.serverSettings {
            guard let value = defaults.object(forKey: name) else { continue }
            defaults.set(value, forKey: Self.setting(name, servers.first ?? serverURL))
            defaults.removeObject(forKey: name)
        }
    }

    /// The last known lists, so the pages show instantly while the new ones load.
    private func loadList() {
        let list = Self.read([Asset].self, listFile) ?? []
        assets = list
        revision += 1
        status = list.isEmpty ? "" : String(localized: "\(list.count) items")
        if let saved = Self.read(SavedCollections.self, collectionsFile) {
            (people, albums, tags, ownedAlbums) = (saved.people, saved.albums, saved.tags, saved.ownedAlbums)
        }
    }

    /// People, albums and tags as last loaded, next to the asset list.
    private struct SavedCollections: Codable {
        let people: [Person]
        let albums: [Album]
        let tags: [Tag]
        let ownedAlbums: Set<String>?
    }

    private var collectionsFile: URL { listFile.deletingLastPathComponent().appending(path: "collections.json") }

    /// A person's, album's or tag's photos as last loaded: "pages/albumId=….json".
    private func pageFile(_ filter: [String: String]) -> URL {
        let name = filter.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return listFile.deletingLastPathComponent().appending(path: "pages/\(name.replacingOccurrences(of: "/", with: "_")).json")
    }

    private static func read<T: Decodable>(_ type: T.Type, _ file: URL) -> T? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write(_ value: some Encodable, _ file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    /// Tries the address and key, and only keeps the key if the server takes it. Returns why it didn't work, or nil.
    /// The address is kept either way, so the start command (Settings > Server) can wait on it.
    /// A new address is added to the servers and, with `switching`, switched to (else only its key is saved).
    func connect(server: String, key: String, switching: Bool = true) async -> String? {
        guard let url = ImmichAPI.address(server) else { return String(localized: "That isn’t a server address.") }
        if api == nil {
            serverURL = url.absoluteString
            UserDefaults.standard.set(serverURL, forKey: "server")
        }
        let candidate = ImmichAPI(server: url, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
        if let problem = await candidate.check() { return problem }
        Keychain.save(candidate.key, url.absoluteString)
        if !servers.contains(url.absoluteString) {
            servers.append(url.absoluteString)
            UserDefaults.standard.set(servers, forKey: "servers")
        }
        if switching || url.absoluteString == serverURL || api == nil { await use(candidate) }
        return nil
    }

    /// Switches to a server connected to before, with its saved key.
    func switchTo(_ server: String) async {
        guard server != serverURL || api == nil, let key = Keychain.load(server), let url = URL(string: server) else { return }
        await use(ImmichAPI(server: url, key: key))
    }

    /// Forgets a server: its key, list and thumbnails. If it's the current one, switches to another, or back to the connection form.
    func remove(_ server: String) async {
        guard !ImmichAPI.folder(server).isEmpty else { return } // never the whole base folder
        servers.removeAll { $0 == server }
        UserDefaults.standard.set(servers, forKey: "servers")
        Keychain.delete(server)
        for name in Self.serverSettings { UserDefaults.standard.removeObject(forKey: Self.setting(name, server)) }
        if server == serverURL {
            if let next = servers.first { await switchTo(next) } else { await stopSync(); api = nil }
        }
        let (thumbs, _, list) = Self.stores(base, server)
        try? FileManager.default.removeItem(at: thumbs.dir.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: list.deletingLastPathComponent())
    }

    private func use(_ candidate: ImmichAPI) async {
        let server = candidate.server.absoluteString
        if server != serverURL || api == nil {
            await stopSync()
            serverURL = server
            UserDefaults.standard.set(server, forKey: "server")
            (thumbs, faces, listFile) = Self.stores(base, server)
            (people, albums, tags, collectionsError, canDownload, trashEnabled) = ([], [], [], nil, nil, true)
            ownedAlbums = nil
            loadList()
        }
        api = candidate
        Task { await launch() }
    }

    private func stopSync() async {
        syncTask?.cancel()
        await syncTask?.value
    }

    /// At launch and after switching servers: start the server first if Settings > Server says so and it isn't answering, then sync.
    func launch() async {
        if !serverBusy, UserDefaults.standard.bool(forKey: Self.setting("serverStartAtLaunch", serverURL)), api != nil,
           !command("serverStart").isEmpty, let url = URL(string: serverURL), !(await ImmichAPI.ping(url)) {
            await startServer()
        } else {
            await refresh()
        }
    }

    // MARK: Starting and stopping the server, with the commands from Settings > Server

    private(set) var serverBusy = false
    /// The output of the last start or stop command, when it failed.
    private(set) var serverError: String?
    /// Only servers this app started are stopped at quit.
    private var startedServers: Set<String> = []

    /// Settings > Server keeps these for each server, as "serverStart http://localhost:2283".
    static let serverSettings = ["serverStart", "serverStop", "serverStartAtLaunch", "serverStopAtQuit"]
    static func setting(_ name: String, _ server: String) -> String { "\(name) \(server)" }

    /// The current server's start or stop command, or another server's.
    func command(_ name: String, for server: String? = nil) -> String {
        (UserDefaults.standard.string(forKey: Self.setting(name, server ?? serverURL)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the start command, waits until the server answers, then syncs.
    func startServer() async {
        let server = serverURL
        guard !serverBusy, await run("serverStart", String(localized: "Starting the server…")) else { return }
        startedServers.insert(server)
        serverBusy = true
        defer { serverBusy = false }
        status = String(localized: "Waiting for the server…")
        // ponytail: fixed 3 minute wait; make it a setting if a slow NAS needs longer
        for _ in 0..<90 {
            guard serverURL == server else { return } // switched to another server meanwhile
            if let url = URL(string: server), await ImmichAPI.ping(url) {
                serverBusy = false
                await refresh()
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        status = String(localized: "The server didn’t answer within 3 minutes")
        serverError = status
    }

    func stopServer() async {
        guard !serverBusy, await run("serverStop", String(localized: "Stopping the server…")) else { return }
        startedServers.remove(serverURL)
        status = String(localized: "Server stopped")
    }

    #if os(macOS)
    /// At quit, without waiting: each server this app started, with its own stop command. The commands keep running after the app is gone.
    func stopServerAtQuit() {
        for server in startedServers where UserDefaults.standard.bool(forKey: Self.setting("serverStopAtQuit", server)) {
            let stop = command("serverStop", for: server)
            if !stop.isEmpty { try? Self.shell(stop).run() }
        }
    }

    private func run(_ key: String, _ message: String) async -> Bool {
        let text = command(key)
        guard !text.isEmpty else { return false }
        serverBusy = true
        defer { serverBusy = false }
        status = message
        serverError = nil
        let process = Self.shell(text)
        let log = FileManager.default.temporaryDirectory.appending(path: "ImmichViewer-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        // a file rather than a pipe: something the command leaves running in the background could hold a pipe open forever
        let out = try? FileHandle(forWritingTo: log)
        process.standardOutput = out
        process.standardError = out
        let code: Int32 = await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(returning: -1) }
        }
        try? out?.close()
        guard code != 0 else { return true }
        let output = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        status = String(localized: "The command failed (exit code \(code))")
        serverError = output.isEmpty ? status : String(output.suffix(2000))
        return false
    }

    /// A login zsh, so the PATH has Homebrew, Docker and OrbStack as in Terminal.
    nonisolated private static func shell(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
    #else
    /// iOS can't run commands.
    private func run(_ key: String, _ message: String) async -> Bool { false }
    #endif

    /// Reloads the asset list, then downloads any thumbnails not cached yet.
    func refresh() async {
        guard let api, !syncing else { return }
        syncing = true
        let task = Task {
            await self.sync(api)
            self.syncing = false
        }
        syncTask = task
        await task.value
    }

    private func sync(_ api: ImmichAPI) async {
        status = String(localized: "Syncing the list…")
        async let collections: Void = loadCollections() // alongside, not after: people and albums are much quicker
        let list: [Asset]
        do {
            list = try await api.timeline()
        } catch {
            status = String(localized: "Sync failed: \(error.localizedDescription)")
            await collections
            return
        }
        await collections
        guard !Task.isCancelled else { return }
        assets = list
        revision += 1
        saveList()

        #if os(macOS)
        await thumbs.downloadMissing(list.map(\.id), api: api) { done, total, failed in
            self.status = switch (done < total, failed > 0) {
            case (true, false): String(localized: "Downloading thumbnails \(done) of \(total)")
            case (true, true): String(localized: "Downloading thumbnails \(done) of \(total), \(failed) failed")
            case (false, false): String(localized: "\(list.count) items")
            case (false, true): String(localized: "\(list.count) items, \(failed) failed")
            }
        }
        #else
        status = String(localized: "\(list.count) items") // a phone loads thumbnails as they are shown, not the whole library
        #endif
    }

    private func saveList() { Self.write(assets, listFile) }

    /// People and albums; a failure only shows on those pages, the timeline keeps working.
    func loadCollections() async {
        guard let api else { return }
        trashEnabled = (try? await api.trashEnabled()) ?? true
        do {
            async let people = api.people()
            async let albums = api.albums()
            let (newPeople, newAlbums) = try await (people, albums)
            let owned = (try? await api.ownedAlbumIDs()) ?? nil
            let newTags = (try? await api.tags()) ?? [] // a key without tag.read just shows no tags
            guard !Task.isCancelled, self.api?.server == api.server else { return } // switched servers meanwhile
            // only what changed, so the pages don't redraw for nothing
            if newPeople != self.people { self.people = newPeople }
            if newAlbums != self.albums { self.albums = newAlbums }
            if owned != ownedAlbums { ownedAlbums = owned }
            if newTags != tags { tags = newTags }
            collectionsError = nil
            Self.write(SavedCollections(people: newPeople, albums: newAlbums, tags: newTags, ownedAlbums: owned), collectionsFile)
        } catch {
            collectionsError = error.localizedDescription
        }
    }

    /// One person's, album's or tag's photos as last loaded, to show while `assets` gets the current ones.
    func savedAssets(_ filter: [String: String]) -> [Asset]? { Self.read([Asset].self, pageFile(filter)) }

    /// One person's, album's or tag's photos from the server, kept for `savedAssets` next time.
    func assets(_ filter: [String: String]) async throws -> [Asset] {
        guard let api else { return [] }
        let list = try await api.timeline(filter)
        Self.write(list, pageFile(filter))
        return list
    }

    /// The large (~1440 px) version for the single-photo view. Not cached on disk.
    #if os(macOS)
    func preview(_ asset: Asset) async -> NSImage? {
        guard let api, let data = try? await api.thumbnail(asset.id, size: "preview") else { return nil }
        return NSImage(data: data)
    }
    #endif

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
    func player(for asset: Asset) -> AVPlayer? { player(video: asset.id) }

    /// A video asset by id, such as a Live Photo's moving part.
    func player(video id: String) -> AVPlayer? {
        guard let api else { return nil }
        let url = api.server.appending(path: "api/assets/\(id)/video/playback")
        // ponytail: header option key is undocumented but long-standing; a signed URL would replace it if it ever breaks
        let video = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["x-api-key": api.key]])
        return AVPlayer(playerItem: AVPlayerItem(asset: video))
    }

    func openInBrowser(_ asset: Asset) {
        guard let api else { return }
        #if os(macOS)
        NSWorkspace.shared.open(api.server.appending(path: "photos/\(asset.id)"))
        #else
        UIApplication.shared.open(api.server.appending(path: "photos/\(asset.id)"))
        #endif
    }

    // MARK: Editing. Each change goes to the server first; the local list follows only if it worked.
    // Changes register their opposite with `undo` (the window's ⌘Z), and the opposite registers the change again (⇧⌘Z).

    /// Why the last change failed, for an alert.
    var editError: String?
    /// Counts changes, so person and album pages and the info panel reload.
    private(set) var edits = 0
    /// False when the server deletes for good (its trash is turned off).
    private(set) var trashEnabled = true

    /// Runs a change on the server. False, with `editError` set, if it failed.
    private func change(_ work: (ImmichAPI) async throws -> Void) async -> Bool {
        guard let api else { return false }
        do {
            try await work(api)
            edits += 1
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    private func register(_ undo: UndoManager?, _ name: String, _ action: @escaping @MainActor (Library) async -> Void) {
        undo?.registerUndo(withTarget: self) { library in Task { @MainActor in await action(library) } }
        undo?.setActionName(name)
    }

    /// Changes the timeline as the server just did, without reloading it.
    private func patch(_ change: (inout [Asset]) -> Void) {
        change(&assets)
        revision += 1
        saveList()
        if !syncing { status = String(localized: "\(assets.count) items") }
    }

    func favorite(_ ids: [String], _ on: Bool, undo: UndoManager?) async {
        guard await change({ try await $0.send("PUT", "assets", json: ["ids": ids, "isFavorite": on]) }) else { return }
        let set = Set(ids)
        patch { list in for i in list.indices where set.contains(list[i].id) { list[i].isFavorite = on } }
        // ponytail: undo sets all of them back the other way, also ones that already were
        register(undo, on ? String(localized: "Favorite") : String(localized: "Unfavorite")) { await $0.favorite(ids, !on, undo: undo) }
    }

    /// Archived photos leave the timeline (they stay in albums and on the web UI's Archive page).
    func archive(_ ids: [String], _ on: Bool, undo: UndoManager?) async {
        guard await change({ try await $0.send("PUT", "assets", json: ["ids": ids, "visibility": on ? "archive" : "timeline"]) })
        else { return }
        if on {
            let set = Set(ids)
            patch { $0.removeAll { set.contains($0.id) } }
        } else {
            await refresh()
        }
        register(undo, on ? String(localized: "Archive") : String(localized: "Unarchive")) { await $0.archive(ids, !on, undo: undo) }
    }

    /// Moves photos to the trash (Immich empties it after 30 days), or deletes them for good if the server's trash is off.
    func trash(_ ids: [String], undo: UndoManager?) async {
        guard await change({ try await $0.send("DELETE", "assets", json: ["ids": ids, "force": false]) }) else { return }
        let set = Set(ids)
        patch { $0.removeAll { set.contains($0.id) } }
        if trashEnabled { register(undo, String(localized: "Delete")) { await $0.restore(ids, undo: undo) } }
    }

    /// Gone for good, from the trash or (with the trash off) from anywhere.
    func deleteForever(_ ids: [String]) async {
        guard await change({ try await $0.send("DELETE", "assets", json: ["ids": ids, "force": true]) }) else { return }
        let set = Set(ids)
        patch { $0.removeAll { set.contains($0.id) } }
    }

    func emptyTrash() async {
        _ = await change { try await $0.send("POST", "trash/empty") }
    }

    func restoreAll() async {
        if await change({ try await $0.send("POST", "trash/restore") }) { await refresh() }
    }

    func restore(_ ids: [String], undo: UndoManager?) async {
        guard await change({ try await $0.send("POST", "trash/restore/assets", json: ["ids": ids]) }) else { return }
        await refresh()
        register(undo, String(localized: "Delete")) { await $0.trash(ids, undo: undo) }
    }

    /// Moves the photos' dates and times by the same amount, keeping their time zones.
    func shiftDates(_ ids: [String], minutes: Int, undo: UndoManager?) async {
        guard minutes != 0, await change({ try await $0.send("PUT", "assets", json: ["ids": ids, "dateTimeRelative": minutes]) })
        else { return }
        let set = Set(ids)
        patch { list in
            for i in list.indices where set.contains(list[i].id) { list[i].date += Double(minutes) * 60 }
            list.sort { $0.date > $1.date }
        }
        register(undo, String(localized: "Adjust Date and Time")) { await $0.shiftDates(ids, minutes: -minutes, undo: undo) }
    }

    /// `old`: where a single photo was, so undo can put it back (a photo without a place can't be made placeless again).
    func locate(_ ids: [String], at place: CLLocationCoordinate2D, was old: CLLocationCoordinate2D?, undo: UndoManager?) async {
        guard await change({ try await $0.send("PUT", "assets", json: ["ids": ids, "latitude": place.latitude, "longitude": place.longitude]) })
        else { return }
        if let old { register(undo, String(localized: "Set Location")) { await $0.locate(ids, at: old, was: place, undo: undo) } }
    }

    func describe(_ id: String, _ text: String, was old: String, undo: UndoManager?) async {
        guard await change({ try await $0.send("PUT", "assets/\(id)", json: ["description": text]) }) else { return }
        register(undo, String(localized: "Edit Description")) { await $0.describe(id, old, was: text, undo: undo) }
    }

    /// 1–5 stars, or nil for none.
    func rate(_ id: String, _ stars: Int?, was old: Int?, undo: UndoManager?) async {
        guard await change({ try await $0.send("PUT", "assets/\(id)", json: ["rating": stars ?? NSNull()]) }) else { return }
        register(undo, String(localized: "Rate")) { await $0.rate(id, old, was: stars, undo: undo) }
    }

    /// The ids the server says it added or removed (ones already in, or not in, the album don't count).
    private func albumAssets(_ method: String, _ album: String, _ ids: [String]) async -> [String] {
        struct Result: Decodable { let id: String; let success: Bool }
        var done: [String] = []
        guard await change({ api in
            let data = try await api.send(method, "albums/\(album)/assets", json: ["ids": ids])
            done = (try? JSONDecoder().decode([Result].self, from: data))?.filter(\.success).map(\.id) ?? ids
        }) else { return [] }
        await loadCollections()
        return done
    }

    func add(_ ids: [String], to album: String, undo: UndoManager?) async {
        let added = await albumAssets("PUT", album, ids)
        if !added.isEmpty { register(undo, String(localized: "Add to Album")) { await $0.remove(added, from: album, undo: undo) } }
    }

    func remove(_ ids: [String], from album: String, undo: UndoManager?) async {
        let removed = await albumAssets("DELETE", album, ids)
        if !removed.isEmpty { register(undo, String(localized: "Remove from Album")) { await $0.add(removed, to: album, undo: undo) } }
    }

    /// A new album, with `ids` in it. Nil if it failed.
    func createAlbum(_ name: String, description: String, with ids: [String]) async -> Album? {
        var album: Album?
        guard await change({ api in
            let data = try await api.send("POST", "albums", json: ["albumName": name, "description": description, "assetIds": ids])
            album = try JSONDecoder().decode(Album.self, from: data)
        }) else { return nil }
        await loadCollections()
        return album
    }

    /// Name, description and cover.
    func update(_ album: Album, was old: Album, undo: UndoManager?) async {
        var json: [String: Any] = ["albumName": album.albumName, "description": album.description ?? ""]
        if let cover = album.albumThumbnailAssetId { json["albumThumbnailAssetId"] = cover }
        guard await change({ try await $0.send("PATCH", "albums/\(album.id)", json: json) }) else { return }
        await loadCollections()
        register(undo, String(localized: "Edit Album")) { await $0.update(old, was: album, undo: undo) }
    }

    /// The album goes; its photos stay.
    func delete(_ album: Album) async {
        guard await change({ try await $0.send("DELETE", "albums/\(album.id)") }) else { return }
        await loadCollections()
    }

    /// Name, birthday and hidden (a hidden person leaves the People page).
    func update(_ person: Person, hidden: Bool = false, was old: Person, undo: UndoManager?) async {
        guard await change({ try await $0.send("PUT", "people/\(person.id)",
                                               json: ["name": person.name, "birthDate": person.birthDate ?? NSNull(), "isHidden": hidden]) })
        else { return }
        await loadCollections()
        register(undo, hidden ? String(localized: "Hide Person") : String(localized: "Edit Person")) {
            await $0.update(old, was: person, undo: undo)
        }
    }

    /// Uses this person's face in `asset` as their picture.
    func setProfilePhoto(_ person: String, from asset: String) async {
        guard await change({ try await $0.send("PUT", "people/\(person)", json: ["featureFaceAssetId": asset]) }) else { return }
        faces.forget(person)
        await loadCollections()
    }

    // MARK: Tags

    /// Tags the photos with `name` ("Trips/Japan" nests), making the tag if it is new.
    func tag(_ ids: [String], _ name: String, undo: UndoManager?) async {
        var tag: Tag?
        guard await change({ api in
            tag = try JSONDecoder().decode([Tag].self, from: await api.send("PUT", "tags", json: ["tags": [name]])).first
            if let tag { try await api.send("PUT", "tags/assets", json: ["tagIds": [tag.id], "assetIds": ids]) }
        }), let tag else { return }
        if let list = try? await api?.tags() { tags = list }
        register(undo, String(localized: "Add Tag")) { await $0.untag(ids, tag, undo: undo) }
    }

    func untag(_ ids: [String], _ tag: Tag, undo: UndoManager?) async {
        guard await change({ try await $0.send("DELETE", "tags/\(tag.id)/assets", json: ["ids": ids]) }) else { return }
        register(undo, String(localized: "Remove Tag")) { await $0.tag(ids, tag.value, undo: undo) }
    }

    /// The tag goes; its photos stay.
    func delete(_ tag: Tag) async {
        if await change({ try await $0.send("DELETE", "tags/\(tag.id)") }) { tags.removeAll { $0.id == tag.id } }
    }

    // MARK: People

    /// `others` become `person`: their faces move over and they are gone. Can't be undone.
    func merge(_ others: [String], into person: String) async {
        guard await change({ try await $0.send("POST", "people/\(person)/merge", json: ["ids": others]) }) else { return }
        faces.forget(person)
        await loadCollections()
    }

    /// A face in a photo is someone else's.
    func reassign(face: String, to person: String, from old: String, undo: UndoManager?) async {
        guard await change({ try await $0.send("PUT", "faces/\(face)", json: ["id": person]) }) else { return }
        await loadCollections()
        register(undo, String(localized: "Change Person")) { await $0.reassign(face: face, to: old, from: person, undo: undo) }
    }

    // MARK: Rotating, downloading and uploading

    /// Turns photos `angle` degrees clockwise, on top of earlier edits. The server keeps the original file as it was.
    func rotate(_ ids: [String], by angle: Int, undo: UndoManager?) async {
        guard await change({ api in
            for id in ids {
                let old = (try JSONSerialization.jsonObject(with: await api.get("assets/\(id)/edits")) as? [String: Any])?["edits"]
                var edits = (old as? [[String: Any]] ?? []).map { ["action": $0["action"] ?? "", "parameters": $0["parameters"] ?? [:]] }
                let i = edits.firstIndex { $0["action"] as? String == "rotate" }
                let was = i.flatMap { (edits[$0]["parameters"] as? [String: Any])?["angle"] as? Int } ?? 0
                let now = ((was + angle) % 360 + 360) % 360
                if let i { edits.remove(at: i) }
                if now != 0 { edits.append(["action": "rotate", "parameters": ["angle": now]]) }
                if edits.isEmpty {
                    try await api.send("DELETE", "assets/\(id)/edits")
                } else {
                    try await api.send("PUT", "assets/\(id)/edits", json: ["edits": edits])
                }
            }
        }) else { return }
        register(undo, String(localized: "Rotate")) { await $0.rotate(ids, by: -angle, undo: undo) }
        // ponytail: the server makes the new thumbnails in the background; one fixed wait, then they are fetched again
        try? await Task.sleep(for: .seconds(3))
        for id in ids {
            api?.forgetCached(id)
            thumbs.forget(id)
        }
        revision += 1
        edits += 1
    }

    /// The original files, and a Live Photo's video beside its still under the same name. On the Mac, saved to Downloads
    /// and shown in Finder; on iOS, in a new temporary folder for the share sheet.
    @discardableResult
    func download(_ assets: [Asset]) async -> [URL] {
        let ids = assets.map(\.id)
        guard let api else { return [] }
        #if os(macOS)
        let folder = URL.downloadsDirectory
        #else
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        var saved: [URL] = []
        let progress = Progress(totalUnitCount: Int64(ids.count))
        transfer = progress
        defer { transfer = nil }
        for (n, id) in ids.enumerated() where !progress.isCancelled {
            transferStep = n + 1
            do {
                let (file, name) = try await api.download(id, progress: progress)
                let target = Self.unused(folder.appending(path: name))
                try FileManager.default.moveItem(at: file, to: target)
                saved.append(target)
                if assets[n].isLive == true, let video = try await api.detail(id).livePhotoVideoId {
                    let (file, name) = try await api.download(video) // small: not part of the progress
                    let pair = Self.unused(target.deletingPathExtension().appendingPathExtension((name as NSString).pathExtension))
                    try FileManager.default.moveItem(at: file, to: pair)
                    saved.append(pair)
                }
            } catch {
                if !progress.isCancelled { editError = error.localizedDescription }
                break
            }
        }
        #if os(iOS)
        if progress.isCancelled || saved.isEmpty { // nothing to share
            try? FileManager.default.removeItem(at: folder)
            return []
        }
        #endif
        #if os(macOS)
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        #endif
        return saved
    }

    /// `url`, or "name 2.jpg", "name 3.jpg"… if that is taken.
    private static func unused(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var url = url, n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Uploads files (into `album` too, if given), then syncs. Files the server already has count as uploaded.
    func upload(_ files: [URL], album: String?) async {
        guard let api, !files.isEmpty else { return }
        var ids: [String] = []
        var failures: [String] = []
        for (n, file) in files.enumerated() {
            status = String(localized: "Uploading \(n + 1) of \(files.count)")
            do {
                ids.append(try await api.upload(file))
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { editError = failures.prefix(10).joined(separator: "\n") }
        if let album, !ids.isEmpty { _ = await albumAssets("PUT", album, ids) }
        edits += 1
        await refresh()
    }
}
