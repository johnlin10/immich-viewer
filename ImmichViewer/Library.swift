import AppKit
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
    private(set) var syncing = false
    private(set) var people: [Person] = []
    private(set) var albums: [Album] = []
    private(set) var tags: [Tag] = []
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
            status = String(localized: "\(list.count) items")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopServerAtQuit() }
        }
    }

    /// Tries the address and key, and only keeps the key if the server takes it. Returns why it didn't work, or nil.
    /// The address is kept either way, so the start command (Settings > Server) can wait on it.
    func connect(server: String, key: String) async -> String? {
        guard let url = ImmichAPI.address(server) else { return String(localized: "That isn’t a server address.") }
        serverURL = url.absoluteString
        UserDefaults.standard.set(serverURL, forKey: "server")
        let candidate = ImmichAPI(server: url, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
        if let problem = await candidate.check() { return problem }
        Keychain.save(candidate.key)
        api = candidate
        Task { await refresh() }
        return nil
    }

    /// At launch: start the server first if Settings > Server says so and it isn't answering, then sync.
    func launch() async {
        if UserDefaults.standard.bool(forKey: "serverStartAtLaunch"), api != nil, !command("serverStart").isEmpty,
           let url = URL(string: serverURL), !(await ImmichAPI.ping(url)) {
            await startServer()
        } else {
            await refresh()
        }
    }

    // MARK: Starting and stopping the server, with the commands from Settings > Server

    private(set) var serverBusy = false
    /// The output of the last start or stop command, when it failed.
    private(set) var serverError: String?
    /// Only a server this app started is stopped at quit.
    private var startedServer = false

    func command(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the start command, waits until the server answers, then syncs.
    func startServer() async {
        guard !serverBusy, await run("serverStart", String(localized: "Starting the server…")) else { return }
        startedServer = true
        serverBusy = true
        defer { serverBusy = false }
        status = String(localized: "Waiting for the server…")
        // ponytail: fixed 3 minute wait; make it a setting if a slow NAS needs longer
        for _ in 0..<90 {
            if let url = URL(string: serverURL), await ImmichAPI.ping(url) {
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
        startedServer = false
        status = String(localized: "Server stopped")
    }

    /// At quit, without waiting: the command keeps running after the app is gone.
    func stopServerAtQuit() {
        guard startedServer, UserDefaults.standard.bool(forKey: "serverStopAtQuit"), !command("serverStop").isEmpty else { return }
        try? Self.shell(command("serverStop")).run()
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

    /// Reloads the asset list, then downloads any thumbnails not cached yet.
    func refresh() async {
        guard let api, !syncing else { return }
        syncing = true
        defer { syncing = false }
        status = String(localized: "Syncing the list…")
        let list: [Asset]
        do {
            list = try await api.timeline()
        } catch {
            status = String(localized: "Sync failed: \(error.localizedDescription)")
            return
        }
        assets = list
        revision += 1
        saveList()
        await loadCollections()

        await thumbs.downloadMissing(list.map(\.id), api: api) { done, total, failed in
            self.status = switch (done < total, failed > 0) {
            case (true, false): String(localized: "Downloading thumbnails \(done) of \(total)")
            case (true, true): String(localized: "Downloading thumbnails \(done) of \(total), \(failed) failed")
            case (false, false): String(localized: "\(list.count) items")
            case (false, true): String(localized: "\(list.count) items, \(failed) failed")
            }
        }
    }

    private func saveList() {
        try? FileManager.default.createDirectory(at: listFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(assets).write(to: listFile, options: .atomic)
    }

    /// People and albums; a failure only shows on those pages, the timeline keeps working.
    func loadCollections() async {
        guard let api else { return }
        trashEnabled = (try? await api.trashEnabled()) ?? true
        do {
            async let people = api.people()
            async let albums = api.albums()
            (self.people, self.albums) = try await (people, albums)
            collectionsError = nil
            tags = (try? await api.tags()) ?? [] // a key without tag.read just shows no tags
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

    /// Saves the original files to Downloads and shows them in Finder.
    func download(_ ids: [String]) async {
        guard let api else { return }
        var saved: [URL] = []
        for (n, id) in ids.enumerated() {
            status = String(localized: "Downloading \(n + 1) of \(ids.count)")
            do {
                let (file, name) = try await api.download(id)
                let target = Self.unused(URL.downloadsDirectory.appending(path: name))
                try FileManager.default.moveItem(at: file, to: target)
                saved.append(target)
            } catch {
                editError = error.localizedDescription
                break
            }
        }
        status = String(localized: "\(assets.count) items")
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
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
