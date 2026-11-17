import Foundation
import ImageIO

/// Thumbnails kept on disk (~15 KB each) plus decoded images in memory, so scrolling never waits on the server.
/// Images are decoded at the size the grid needs (`pixels`, the longest side; 0 = as stored), so the dense
/// zoom levels keep tens of thousands of them in memory and scrolling back doesn't decode again.
/// `@unchecked Sendable`: only NSCache and FileManager are shared, and both are thread-safe.
final class ThumbnailStore: @unchecked Sendable {
    let dir: URL
    private let memory = NSCache<NSString, CGImage>()
    private let fetch: @Sendable (ImmichAPI, String) async throws -> Data

    /// `fetch` downloads one image; the default is an asset's small thumbnail.
    init(dir: URL, fetch: @escaping @Sendable (ImmichAPI, String) async throws -> Data = { try await $0.thumbnail($1) }) {
        self.dir = dir
        self.fetch = fetch
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.totalCostLimit = Int(min(ProcessInfo.processInfo.physicalMemory / 4, 2 << 30)) // decoded bytes
    }

    /// The decode size for a cell of `side` points: small sizes share a few tiers so the cache is reused.
    static func pixels(forSide side: Double, scale: Double) -> Int {
        let longSide = side * scale * 4 / 3 // a 4:3 photo still fills the square
        return longSide <= 128 ? 128 : longSide <= 256 ? 256 : 0
    }

    private func file(_ id: String) -> URL { dir.appending(path: id) }
    private func key(_ id: String, _ pixels: Int) -> NSString { "\(id)@\(pixels)" as NSString }

    func cached(_ id: String, pixels: Int) -> CGImage? { memory.object(forKey: key(id, pixels)) }

    /// The sharpest version already decoded in memory, if any.
    func anyCached(_ id: String) -> CGImage? { [0, 256, 128].lazy.compactMap { self.cached(id, pixels: $0) }.first }

    /// Memory, then disk, then the server. Decodes off the main thread.
    func image(_ id: String, pixels: Int, api: ImmichAPI) async -> CGImage? {
        if let image = cached(id, pixels: pixels) { return image }
        var data = try? Data(contentsOf: file(id))
        if data == nil {
            guard !Task.isCancelled, let fetched = try? await fetch(api, id) else { return nil }
            try? fetched.write(to: file(id), options: .atomic)
            data = fetched
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceCreateThumbnailFromImageAlways: true]
        if pixels > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = pixels }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        memory.setObject(image, forKey: key(id, pixels), cost: image.bytesPerRow * image.height)
        return image
    }

    /// Drops a picture that changed on the server (a new profile photo, a rotated photo), so the next request downloads it again.
    func forget(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
        for pixels in [0, 128, 256] { memory.removeObject(forKey: key(id, pixels)) }
    }

    /// Bytes on disk.
    func diskSize() -> Int {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }

    /// Forgets everything; images download again when they are next shown.
    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Downloads every thumbnail not on disk yet, 8 at a time. Reports (done, total, failed).
    func downloadMissing(_ ids: [String], api: ImmichAPI, progress: @escaping @MainActor (Int, Int, Int) -> Void) async {
        let onDisk = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let missing = ids.filter { !onDisk.contains($0) }
        var started = 0, done = 0, failed = 0
        await withTaskGroup(of: Bool.self) { group in
            func collect(_ ok: Bool?) async {
                guard let ok else { return }
                done += 1
                if !ok { failed += 1 }
                if done % 200 == 0 { await progress(done, missing.count, failed) }
            }
            for id in missing {
                if started - done >= 8 { await collect(await group.next()) }
                group.addTask {
                    guard let data = try? await self.fetch(api, id) else { return false }
                    try? data.write(to: self.file(id), options: .atomic)
                    return true
                }
                started += 1
            }
            while let ok = await group.next() { await collect(ok) }
        }
        await progress(missing.count, missing.count, failed)
    }
}
