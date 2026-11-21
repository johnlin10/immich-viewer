#if os(iOS)
import Photos
import PhotosUI
import SwiftUI

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
        return UploadFile(url: url, name: ext.isEmpty ? base : "\(base).\(ext)", created: asset.creationDate,
                          modified: asset.modificationDate, favorite: asset.isFavorite && !liveVideo, liveVideo: liveVideo, temporary: true)
    }
    var out: [UploadFile] = []
    if asset.mediaSubtypes.contains(.photoLive), let pair = first(.fullSizePairedVideo, .pairedVideo) {
        out.append(try await copy(pair, liveVideo: true))
    }
    out.append(try await copy(main))
    return out
}

/// What the picker hands over without library access: a copy of the file, kept until uploaded.
private struct PickedFile: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let name = received.file.lastPathComponent
            let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: url)
            return PickedFile(url: url, name: name)
        }
    }
}
#endif
