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
        return [UploadFile(url: file.url, name: file.name, temporary: true)]
    }
}

/// An asset's files, copied out of Photos (downloaded from iCloud if need be): a Live Photo's video, then the still.
private func files(of asset: PHAsset) async throws -> [UploadFile] {
    let resources = PHAssetResource.assetResources(for: asset)
    func first(_ types: PHAssetResourceType...) -> PHAssetResource? {
        types.lazy.compactMap { type in resources.first { $0.type == type } }.first
    }
    let video = asset.mediaType == .video
    guard let main = video ? first(.fullSizeVideo, .video) : first(.fullSizePhoto, .photo) else { throw CocoaError(.fileReadNoSuchFile) }
    // an edited one is "FullSizeRender.jpg": the original's name, with the edit's extension
    let base = ((first(video ? .video : .photo) ?? main).originalFilename as NSString).deletingPathExtension
    func copy(_ resource: PHAssetResource, liveVideo: Bool = false) async throws -> UploadFile {
        let ext = (resource.originalFilename as NSString).pathExtension
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        var file = url, name = ext.isEmpty ? base : "\(base).\(ext)"
        // some photos (Live Photos other apps saved as a ".pvt" bundle) have a resource that writes no file: take the
        // image as Photos shows it instead
        let written = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if !video, !liveVideo, written?.isRegularFile != true || (written?.fileSize ?? 0) == 0
            || UTType(filenameExtension: ext)?.conforms(to: .image) != true {
            try? FileManager.default.removeItem(at: url)
            let (data, type) = try await imageData(of: asset)
            let ext = type?.preferredFilenameExtension ?? "jpg"
            file = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(ext)
            try data.write(to: file)
            name = "\(base).\(ext)"
        }
        return UploadFile(url: file, name: name, created: asset.creationDate,
                          modified: asset.modificationDate, favorite: asset.isFavorite && !liveVideo, liveVideo: liveVideo, temporary: true)
    }
    var out: [UploadFile] = []
    if asset.mediaSubtypes.contains(.photoLive), let pair = first(.fullSizePairedVideo, .pairedVideo) {
        out.append(try await copy(pair, liveVideo: true))
    }
    out.append(try await copy(main))
    return out
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

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            var source = received.file
            // a Live Photo can come as a ".pvt" bundle, a folder holding the image and its video: the image goes
            if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               let image = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                   .first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
                source = image
            }
            let name = received.file.deletingPathExtension().lastPathComponent + "." + source.pathExtension
            let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: url)
            return PickedFile(url: url, name: name)
        }
    }
}
#endif
