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
    /// How far the download and the upload are, read on the main thread for the views: the Progress objects change on
    /// URLSession's threads, and SwiftUI bound to them straight crashes when several change at once.
    private(set) var transferFraction = 0.0
    private(set) var uploadFraction = 0.0
    /// The upload under way (one at a time); cancel it to stop. `uploadStep` is the item it is on, from 1.
    private(set) var upload: Progress?
    private(set) var uploadStep = 0
    /// Of this upload, the items the server had already (skipped) and the ones that failed so far.
    private(set) var uploadSkipped = 0
    private(set) var uploadFailed = 0
    private(set) var syncing = false
    private(set) var people: [Person] = []
    private(set) var albums: [Album] = []
    private(set) var tags: [Tag] = []
    /// Ids of your own albums (the rest are shared with you); nil if the server can't tell.
    private(set) var ownedAlbums: Set<String>?
    /// Why people or albums couldn't be loaded (for example a key without `person.read`).
    private(set) var collectionsError: String?
    /// Today's memories. Loaded with each sync; not kept on disk.
    private(set) var memories: [Memory] = []
    /// Why they couldn't be loaded (for example a key without `memory.read`); the Collections row then stays out.
    private(set) var memoriesError: String?
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
    /// The live connection to the server, see `listen()`.
    private var listenTask: Task<Void, Never>?

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
        return pagesDir.appending(path: "\(name.replacingOccurrences(of: "/", with: "_")).json")
    }

    private var pagesDir: URL { listFile.deletingLastPathComponent().appending(path: "pages", directoryHint: .isDirectory) }

    nonisolated private static func read<T: Decodable>(_ type: T.Type, _ file: URL) -> T? {
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
            (memories, memoriesError) = ([], nil)
            loadList()
        }
        api = candidate
        Task { await launch() }
    }

    private func stopSync() async {
        stopListening()
        settleTask?.cancel()
        settleTask = nil
        pendingRemoved = []
        pendingChanged = [:]
        (pendingRefresh, sawChange) = (false, false)
        syncTask?.cancel()
        await syncTask?.value
    }

    /// At launch and after switching servers: start the server first if Settings > Server says so and it isn't answering, then sync.
    func launch() async {
        listen()
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
        let (thumbs, pages) = (thumbs, pagesDir) // this server's, whatever is switched to meanwhile
        status = String(localized: "Syncing the list…")
        async let collections: Void = loadCollections() // alongside, not after: people and albums are much quicker
        async let memories: Void = loadMemories()
        let list: [Asset]
        do {
            list = try await api.timeline()
        } catch {
            status = String(localized: "Sync failed: \(error.localizedDescription)")
            await collections
            await memories
            return
        }
        await collections
        await memories
        guard !Task.isCancelled else { return }
        assets = list
        revision += 1
        saveList()
        await pruneCaches(thumbs, pages: pages)
        guard !Task.isCancelled else { return }

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

    /// Deletes thumbnails of photos that are gone: keeps the timeline's, the saved person, album, tag, archive and trash lists',
    /// and album covers (which may not be on the timeline). Off the main actor: it reads every saved list.
    private func pruneCaches(_ thumbs: ThumbnailStore, pages: URL) async {
        let keep = Set(assets.map(\.id) + albums.compactMap(\.albumThumbnailAssetId))
        await Task.detached(priority: .utility) {
            var keep = keep
            for file in (try? FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)) ?? [] {
                keep.formUnion(Self.read([Asset].self, file)?.map(\.id) ?? [])
            }
            thumbs.prune(keeping: keep)
        }.value
    }

    /// People and albums; a failure only shows on those pages, the timeline keeps working.
    func loadCollections() async {
        guard let api else { return }
        let faces = faces // this server's, whatever is switched to meanwhile
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
            faces.prune(keeping: Set(newPeople.map(\.id))) // hidden people come back when shown
            Self.write(SavedCollections(people: newPeople, albums: newAlbums, tags: newTags, ownedAlbums: owned), collectionsFile)
        } catch {
            collectionsError = error.localizedDescription
        }
    }

    /// Today's memories; a failure only hides the row on Collections, no alert.
    func loadMemories() async {
        guard let api else { return }
        do {
            let found = try await api.memories(for: .now)
            guard !Task.isCancelled, self.api?.server == api.server else { return }
            if found != memories { memories = found }
            memoriesError = nil
        } catch {
            guard !Task.isCancelled, self.api?.server == api.server else { return }
            (memories, memoriesError) = ([], error.localizedDescription)
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

    /// Every tag any of these photos has, by name.
    /// ponytail: one request per photo, capped at 100; ask the server per tag if big selections need it exact.
    func tags(on ids: [String]) async -> [Tag] {
        guard let api else { return [] }
        let found = await withTaskGroup(of: [Tag].self) { group in
            for id in ids.prefix(100) { group.addTask { (try? await api.detail(id).tags) ?? [] } }
            return await group.reduce(into: [String: Tag]()) { all, tags in for tag in tags { all[tag.id] = tag } }
        }
        return found.values.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

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

    // MARK: Live changes from the server (web UI, other devices)

    private var pendingRemoved: Set<String> = []
    private var pendingChanged: [String: AssetItem] = [:]
    private var pendingRefresh = false
    /// An update or removal came in, even if the timeline shows nothing new: open Trash, Archive and album pages, a description or a rating may differ.
    private var sawChange = false
    private var settleTask: Task<Void, Never>?

    /// Follows the server's live events until `stopListening()`, reconnecting when the connection drops.
    func listen() {
        listenTask?.cancel()
        guard let api else { return }
        listenTask = Task {
            var connected = false
            while !Task.isCancelled {
                do {
                    for try await event in api.events() where !Task.isCancelled {
                        if case .connected = event {
                            if connected { pendingRefresh = true; scheduleSettle() } // events may have been missed meanwhile
                            connected = true
                        } else {
                            receive(event)
                        }
                    }
                } catch {}
                // ponytail: fixed 5 s retry, no backoff
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopListening() {
        listenTask?.cancel()
        listenTask = nil
    }

    private func receive(_ event: ServerEvent) {
        switch event {
        case .connected: return
        case .removed(let ids):
            sawChange = true
            pendingRemoved.formUnion(ids)
        case .deleted(let ids):
            sawChange = true
            pendingRemoved.formUnion(ids)
            for id in ids { thumbs.forget(id) }
        case .changed(let item):
            sawChange = true
            if !item.onTimeline {
                pendingRemoved.insert(item.id)
            } else if assets.contains(where: { $0.id == item.id }) { // ponytail: a scan per event; an id index if bulk edits feel slow
                pendingChanged[item.id] = item
            } else {
                pendingRefresh = true // just unarchived or restored
            }
        case .added: pendingRefresh = true
        }
        scheduleSettle()
    }

    /// Handles what came in during the next second together: a bulk edit sends one event per photo.
    private func scheduleSettle() {
        guard settleTask == nil else { return }
        settleTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await settle()
        }
    }

    private func settle() async {
        let (removed, changed, refreshing, saw) = (pendingRemoved, pendingChanged, pendingRefresh, sawChange)
        pendingRemoved = []
        pendingChanged = [:]
        (pendingRefresh, sawChange) = (false, false)
        settleTask = nil // events from here on start the next window

        let parser = UTCDateParser()
        var updates: [String: Asset] = [:]
        for old in assets {
            guard let new = changed[old.id]?.asset(using: parser),
                  new.date != old.date || new.isFavorite != (old.isFavorite == true) || new.isLive != (old.isLive == true) else { continue }
            updates[old.id] = new
        }
        let patched = !updates.isEmpty || assets.contains { removed.contains($0.id) }
        // ponytail: a sync already running can bring a just-removed photo back until the next refresh
        if patched { // our own edits come back as events: nothing to do when the list already shows them
            patch { list in
                list.removeAll { removed.contains($0.id) }
                for i in list.indices {
                    guard let new = updates[list[i].id] else { continue }
                    (list[i].date, list[i].isFavorite, list[i].isLive) = (new.date, new.isFavorite, new.isLive)
                }
                if !updates.isEmpty { list.sort { $0.date > $1.date } }
            }
        }
        if refreshing {
            while syncing { try? await Task.sleep(for: .seconds(0.5)) }
            guard !Task.isCancelled else { return }
            await refresh()
        }
        if patched || refreshing || saw { edits += 1 } // open people, album, trash and info pages load again
    }

    // MARK: Editing. Each change goes to the server first; the local list follows only if it worked.
    // Changes register their opposite with `undo` (the window's ⌘Z), and the opposite registers the change again (⇧⌘Z).

    /// Why the last change failed, for an alert.
    var editError: String?
    /// The alert's title when it isn't a failure ("Couldn’t Make the Change"), such as an upload's summary. Cleared with `editError`.
    var editErrorTitle: String?
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
    func tag(_ ids: [String], _ names: [String], undo: UndoManager?) async {
        var added: [Tag] = []
        guard await change({ api in
            added = try JSONDecoder().decode([Tag].self, from: await api.send("PUT", "tags", json: ["tags": names]))
            guard !added.isEmpty else { return }
            struct Count: Decodable { let count: Int }
            let count = try JSONDecoder().decode(Count.self, from: await api.send("PUT", "tags/assets",
                                                                                  json: ["tagIds": added.map(\.id), "assetIds": ids])).count
            // The server answers OK but skips photos it doesn't know or won't let this key change: say so,
            // unless they simply had the tags already.
            if count == 0, let first = ids.first {
                let have = Set((try await api.detail(first).tags ?? []).map(\.id))
                if !added.allSatisfy({ have.contains($0.id) }) { throw TagNotAdded() }
            }
        }), !added.isEmpty else { return }
        if let list = try? await api?.tags() { tags = list }
        register(undo, String(localized: "Add Tag")) { await $0.untag(ids, added, undo: undo) }
    }

    private struct TagNotAdded: LocalizedError {
        var errorDescription: String? {
            String(localized: "The server made the tag but didn’t add it to the photos. Refresh the library, then try again.")
        }
    }

    func untag(_ ids: [String], _ tags: [Tag], undo: UndoManager?) async {
        guard await change({ api in
            for tag in tags { _ = try await api.send("DELETE", "tags/\(tag.id)/assets", json: ["ids": ids]) }
        }) else { return }
        register(undo, String(localized: "Remove Tag")) { await $0.tag(ids, tags.map(\.value), undo: undo) }
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

    /// Reads a photo's edits, lets `change` alter them (action/parameters dictionaries, in order), and saves them:
    /// PUT, or DELETE when none are left.
    private nonisolated static func changeEdits(_ api: ImmichAPI, _ id: String, _ change: (inout [[String: Any]]) -> Void) async throws {
        var edits = try await readEdits(api, id)
        change(&edits)
        if edits.isEmpty {
            try await api.send("DELETE", "assets/\(id)/edits")
        } else {
            try await api.send("PUT", "assets/\(id)/edits", json: ["edits": edits])
        }
    }

    private nonisolated static func readEdits(_ api: ImmichAPI, _ id: String) async throws -> [[String: Any]] {
        let old = (try JSONSerialization.jsonObject(with: await api.get("assets/\(id)/edits")) as? [String: Any])?["edits"]
        return (old as? [[String: Any]] ?? []).map { ["action": $0["action"] ?? "", "parameters": $0["parameters"] ?? [:]] }
    }

    /// Waits for the server's new thumbnails, then shows them.
    private func refetchEdited(_ ids: [String]) async {
        // ponytail: the server makes the new thumbnails in the background; one fixed wait, then they are fetched again
        try? await Task.sleep(for: .seconds(3))
        for id in ids {
            api?.forgetCached(id)
            thumbs.forget(id)
        }
        revision += 1
        edits += 1
    }

    /// Turns photos `angle` degrees clockwise, on top of earlier edits. The server keeps the original file as it was.
    func rotate(_ ids: [String], by angle: Int, undo: UndoManager?) async {
        guard await change({ api in
            for id in ids {
                try await Self.changeEdits(api, id) { edits in
                    let i = edits.firstIndex { $0["action"] as? String == "rotate" }
                    let was = i.flatMap { (edits[$0]["parameters"] as? [String: Any])?["angle"] as? Int } ?? 0
                    let now = ((was + angle) % 360 + 360) % 360
                    if let i { edits.remove(at: i) }
                    if now != 0 { edits.append(["action": "rotate", "parameters": ["angle": now]]) }
                }
            }
        }) else { return }
        register(undo, String(localized: "Rotate")) { await $0.rotate(ids, by: -angle, undo: undo) }
        await refetchEdited(ids)
    }

    /// Crops a photo, keeping its other edits; nil takes the crop away. `was`: the crop before, for undo.
    func crop(_ id: String, to crop: PixelCrop?, was: PixelCrop?, undo: UndoManager?) async {
        guard await change({ api in
            try await Self.changeEdits(api, id) { edits in
                edits.removeAll { $0["action"] as? String == "crop" }
                if let crop {
                    edits.insert(["action": "crop", "parameters": ["x": crop.x, "y": crop.y, "width": crop.width, "height": crop.height]], at: 0)
                }
            }
        }) else { return }
        register(undo, String(localized: "Crop")) { await $0.crop(id, to: was, was: crop, undo: undo) }
        await refetchEdited([id])
    }

    /// What the crop sheet needs: the photo's crop, turn and mirroring, the upright original's size (nil when the server
    /// has none), and its preview as the file is, without edits.
    func cropInfo(_ id: String) async throws -> (crop: PixelCrop?, angle: Int, mirrored: Bool, size: CGSize?, preview: Data) {
        guard let api else { throw URLError(.userAuthenticationRequired) }
        let edits = try await Self.readEdits(api, id)
        func parameters(_ action: String) -> [String: Any]? { edits.first { $0["action"] as? String == action }?["parameters"] as? [String: Any] }
        let crop = parameters("crop").flatMap { p -> PixelCrop? in
            guard let x = p["x"] as? Int, let y = p["y"] as? Int, let w = p["width"] as? Int, let h = p["height"] as? Int else { return nil }
            return PixelCrop(x: x, y: y, width: w, height: h)
        }
        let exif = try await api.detail(id).exifInfo
        var size = exif.flatMap { e in e.exifImageWidth.flatMap { w in e.exifImageHeight.map { CGSize(width: w, height: $0) } } }
        // the server swaps width and height for these orientations
        if let o = exif?.orientation.flatMap({ Int($0) }), [5, 6, 7, 8, -90, 90].contains(o) { size = size.map { CGSize(width: $0.height, height: $0.width) } }
        if let s = size, s.width < 1 || s.height < 1 { size = nil }
        return (crop, parameters("rotate")?["angle"] as? Int ?? 0, parameters("mirror") != nil, size,
                try await api.thumbnail(id, size: "preview", edited: false))
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
        transferFraction = 0
        let poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.transferFraction = progress.fractionCompleted }
        }
        defer { transfer = nil; poll.invalidate() }
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

    /// Uploads `count` items (into `album` too, if given), with `upload` for the progress, then syncs. `item` hands over item
    /// `n`'s files when it's its turn (a Live Photo has two), so they needn't all be copied out first.
    /// Files the server already has count as uploaded.
    func upload(count: Int, album: String?, item: @escaping (Int) async throws -> [UploadFile]) async {
        guard let api, count > 0 else { return }
        var ids: [String] = []
        var failures: [String] = []
        let progress = Progress(totalUnitCount: Int64(count))
        upload = progress
        uploadFraction = 0
        let poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.uploadFraction = progress.fractionCompleted }
        }
        defer { poll.invalidate() }
        uploadStep = 0
        uploadSkipped = 0
        uploadFailed = 0
        var uploaded = 0
        #if os(iOS)
        let background = BackgroundUpload.start(progress: progress, count: count) // goes on after leaving the app
        defer { background.finish(success: !progress.isCancelled) }
        // where the system won't give that task (the simulator, a busy system), the usual short grace after leaving the app
        var grace = UIBackgroundTaskIdentifier.invalid
        grace = UIApplication.shared.beginBackgroundTask(withName: "Upload") { UIApplication.shared.endBackgroundTask(grace) }
        defer { UIApplication.shared.endBackgroundTask(grace) }
        #endif
        defer { upload = nil }
        // a few items at once: while one is copied out of Photos (or downloaded from iCloud) others are sending, so the
        // connection isn't idle between them. They all run on the main actor; only the waiting overlaps.
        let lanes = 4
        var done = 0
        func finished() {
            done += 1
            uploadStep = min(done + 1, count)
            #if os(iOS)
            background.step(uploadStep)
            #endif
        }
        // a passing failure (the proxy in front of the server answering 502 while it's busy, a dropped connection) is
        // tried again twice, after a pause
        func retrying<T>(_ attempt: (Int) async throws -> T) async throws -> T {
            for n in 0... {
                do { return try await attempt(n) } catch {
                    let passing = (error as? ImmichAPI.HTTPError).map { $0.status >= 500 } ?? (error is URLError)
                    guard passing, n < 2, !progress.isCancelled else { throw error }
                    try? await Task.sleep(for: .seconds(n == 0 ? 2 : 5))
                }
            }
            fatalError()
        }
        func one(_ n: Int) async {
            var files: [UploadFile] = []
            // the item's share of the progress, filled when it's done however it went (a failure before or while sending
            // would otherwise leave its share empty and the bar behind the count)
            let unit = Progress(totalUnitCount: 1, parent: progress, pendingUnitCount: 1)
            defer { unit.completedUnitCount = 1 }
            do {
                files = try await item(n)
                var video: String?
                for file in files {
                    // the video is small next to the still: only the still counts for the progress
                    let (id, duplicate) = try await retrying {
                        // a retry weighs nothing in the bar (the item's share fills when it's done), but cancels with it
                        try await api.upload(file, livePhotoVideoId: video, progress: file.liveVideo ? nil
                                             : $0 == 0 ? unit : Progress(totalUnitCount: 1, parent: unit, pendingUnitCount: 0))
                    }
                    if file.liveVideo { video = id; continue }
                    ids.append(id)
                    if duplicate { uploadSkipped += 1 } else { uploaded += 1 }
                }
            } catch {
                if !progress.isCancelled {
                    let name = files.last.map { $0.name ?? $0.url.lastPathComponent }
                    failures.append(name.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription)
                    uploadFailed += 1
                }
            }
            for file in files where file.temporary { try? FileManager.default.removeItem(at: file.url) }
            finished()
        }
        uploadStep = 1
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<count {
                if n >= lanes { await group.next() }
                if progress.isCancelled { break }
                group.addTask { @MainActor in await one(n) }
            }
        }
        #if os(iOS)
        let stopped = background.expired // by the system or its stop button, away from the app: say so, not silently stop
        #else
        let stopped = false
        #endif
        // a summary when not everything simply went up: what the server had already, what failed (the first few, why)
        if uploadSkipped > 0 || !failures.isEmpty || stopped {
            var lines = [stopped ? String(localized: "iOS stopped the upload after \(done) of \(count). Upload them again to send the rest: the ones already on the server are skipped.")
                         : progress.isCancelled ? String(localized: "Cancelled after \(done) of \(count).") : nil,
                         String(localized: "Uploaded: \(uploaded)"),
                         uploadSkipped > 0 ? String(localized: "Already on the server, skipped: \(uploadSkipped)") : nil,
                         failures.isEmpty ? nil : String(localized: "Couldn’t upload: \(failures.count)")].compactMap { $0 }
            if !failures.isEmpty {
                lines.append("")
                lines += failures.prefix(10)
                if failures.count > 10 { lines.append(String(localized: "and \(failures.count - 10) more")) }
            }
            editErrorTitle = stopped ? String(localized: "Upload Stopped")
                : failures.isEmpty ? String(localized: "Upload Finished") : String(localized: "Some Items Couldn’t Be Uploaded")
            editError = lines.joined(separator: "\n")
        }
        if let album, !ids.isEmpty { _ = await albumAssets("PUT", album, ids) }
        edits += 1
        await refresh()
    }
}
