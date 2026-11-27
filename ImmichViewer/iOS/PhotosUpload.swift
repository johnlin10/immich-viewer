#if os(iOS)
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Uploads photos and videos picked from the photo library (into `album` too, if given).
/// With access to the library each goes as Photos has it: the edited version if it was edited, a Live Photo's video too,
/// with Photos' date (for files whose metadata has none), name and favorite. Without, the file the picker hands over
/// goes, dated by its own metadata only.
func uploadFromPhotos(_ items: [PhotosPickerItem], library: Library, album: String?) async {
    let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    var assets: [String: PHAsset] = [:]
    if access == .authorized || access == .limited { // limited: only the photos it was given
        PHAsset.fetchAssets(withLocalIdentifiers: items.compactMap(\.itemIdentifier), options: nil)
            .enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
    }
    await library.upload(count: items.count, album: album) { n in
        if let id = items[n].itemIdentifier, let asset = assets[id] { return try await files(of: asset) }
        guard let file = try await items[n].loadTransferable(type: PickedFile.self) else { throw CocoaError(.fileReadUnknown) }
        return file.files
    }
}

/// An asset's files, copied out of Photos (downloaded from iCloud if need be): a Live Photo's video, then the still.
private func files(of asset: PHAsset) async throws -> [UploadFile] {
    let resources = PHAssetResource.assetResources(for: asset)
    func first(_ types: PHAssetResourceType...) -> PHAssetResource? {
        types.lazy.compactMap { type in resources.first { $0.type == type } }.first
    }
    let video = asset.mediaType == .video
    let live = asset.mediaSubtypes.contains(.photoLive)
    // an edited one is "FullSizeRender.jpg": the original's name, with the edit's extension
    let base = (((first(video ? .video : .photo) ?? resources.first)?.originalFilename ?? "") as NSString).deletingPathExtension
    func file(_ url: URL, _ liveVideo: Bool) -> UploadFile {
        UploadFile(url: url, name: url.pathExtension.isEmpty ? base : "\(base).\(url.pathExtension)", created: asset.creationDate,
                   modified: asset.modificationDate, favorite: asset.isFavorite && !liveVideo, liveVideo: liveVideo, temporary: true)
    }
    var still = try await (video ? first(.fullSizeVideo, .video) : first(.fullSizePhoto, .photo)).asyncMap { try await written($0) } ?? nil
    var pair = live ? try await first(.fullSizePairedVideo, .pairedVideo).asyncMap { try await written($0) } ?? nil : nil
    // some Live Photos (saved by other apps as a ".pvt" bundle) have resources that write no usable file: Photos' own
    // Live Photo for the asset has both halves, still and video
    if live, still == nil || pair == nil {
        for url in [still, pair].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        (still, pair) = try await livePhotoFiles(of: asset)
    }
    if still == nil, !video { // a still photo with the same trouble: the image as Photos shows it
        let (data, type) = try await imageData(of: asset)
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(type?.preferredFilenameExtension ?? "jpg")
        try data.write(to: url)
        still = url
    }
    guard let still else { throw CocoaError(.fileReadNoSuchFile) }
    return (pair.map { [file($0, true)] } ?? []) + [file(still, false)]
}

/// The resource written to a temporary file, or nil when that gives no usable photo or video (nothing written, a
/// folder, an empty file, a ".pvt" name).
private func written(_ resource: PHAssetResource) async throws -> URL? {
    let ext = (resource.originalFilename as NSString).pathExtension
    let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(ext)
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0,
          let type = UTType(filenameExtension: ext), type.conforms(to: .image) || type.conforms(to: .movie) else {
        try? FileManager.default.removeItem(at: url)
        return nil
    }
    return url
}

/// A Live Photo's still and video as Photos puts them together (the edited version if edited), written to temporary files.
private func livePhotoFiles(of asset: PHAsset) async throws -> (URL?, URL?) {
    let options = PHLivePhotoRequestOptions()
    options.isNetworkAccessAllowed = true
    options.version = .current
    options.deliveryMode = .highQualityFormat
    let photo: PHLivePhoto = try await withCheckedThrowingContinuation { done in
        var answered = false // the handler can come more than once; the first full answer counts
        PHImageManager.default().requestLivePhoto(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default,
                                                  options: options) { photo, info in
            guard !answered, info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
            answered = true
            if let photo { done.resume(returning: photo) }
            else { done.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? CocoaError(.fileReadUnknown)) }
        }
    }
    let parts = PHAssetResource.assetResources(for: photo)
    let still = parts.first { $0.type == .fullSizePhoto } ?? parts.first { $0.type == .photo }
    let video = parts.first { $0.type == .fullSizePairedVideo } ?? parts.first { $0.type == .pairedVideo }
    return (try await still.asyncMap { try await written($0) } ?? nil, try await video.asyncMap { try await written($0) } ?? nil)
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

/// A photo's image as Photos shows it (the edited version if edited), downloaded from iCloud if need be, and its type.
private func imageData(of asset: PHAsset) async throws -> (Data, UTType?) {
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.version = .current
    options.deliveryMode = .highQualityFormat // one answer, the full one
    return try await withCheckedThrowingContinuation { done in
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, type, _, info in
            if let data { done.resume(returning: (data, type.flatMap { UTType($0) })) }
            else { done.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? CocoaError(.fileReadUnknown)) }
        }
    }
}

/// What the picker hands over without library access: a copy of the file, kept until uploaded.
// ponytail: dropped files are all copied before uploading, so many big videos take temporary space first.
struct PickedFile: Transferable {
    let url: URL
    let name: String
    /// A Live Photo's video, when it came as a ".pvt" bundle.
    var video: URL?

    /// What to upload: the video first, then the still, linked as a Live Photo.
    var files: [UploadFile] {
        let base = (name as NSString).deletingPathExtension
        return (video.map { [UploadFile(url: $0, name: "\(base).\($0.pathExtension)", liveVideo: true, temporary: true)] } ?? [])
            + [UploadFile(url: url, name: name, temporary: true)]
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let base = received.file.deletingPathExtension().lastPathComponent
            func copy(_ source: URL) throws -> URL {
                let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(source.pathExtension)
                try FileManager.default.copyItem(at: source, to: url)
                return url
            }
            // a Live Photo can come as a ".pvt" bundle, a folder holding the still and its video: both go, as a Live Photo
            if (try? received.file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let inside = try FileManager.default.contentsOfDirectory(at: received.file, includingPropertiesForKeys: nil)
                func of(_ type: UTType) -> URL? { inside.first { UTType(filenameExtension: $0.pathExtension)?.conforms(to: type) == true } }
                guard let image = of(.image) else { throw CocoaError(.fileReadCorruptFile) }
                return PickedFile(url: try copy(image), name: "\(base).\(image.pathExtension)", video: try of(.movie).map(copy))
            }
            return PickedFile(url: try copy(received.file), name: received.file.lastPathComponent)
        }
    }
}
#endif
