import Foundation
import Photos
import CryptoKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// A named album the user can optionally scope a scan to. The default scan covers
// the entire library; picking an album just narrows the fetch.
nonisolated struct AlbumOption: Identifiable, Hashable, Sendable {
    let id: String          // PHAssetCollection.localIdentifier
    let title: String
    let count: Int
}

// The one place the two platforms' image types differ. Everything downstream
// takes a PlatformImage and hands it to SwiftUI's Image(platform:).
#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage

extension NSImage {
    /// UIKit's spelling, so callers don't need their own `#if` to reach the bitmap.
    nonisolated var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
#endif

enum PhotoLibrary {

    // MARK: Authorization

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: Enumeration

    /// All image assets, optionally limited to one album. Runs off the main actor.
    /// `progress` is called with a 0...1 fraction as enumeration advances — reading
    /// per-asset resources (filename, size) is the slow part for large libraries,
    /// so this drives a real progress bar instead of an indeterminate spinner.
    nonisolated static func fetchImageAssets(
        inAlbum albumID: String?,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) -> [ScanItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result: PHFetchResult<PHAsset>
        if let albumID,
           let collection = PHAssetCollection.fetchAssetCollections(
               withLocalIdentifiers: [albumID], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }

        var assets: [ScanItem] = []
        let total = result.count
        assets.reserveCapacity(total)
        let step = max(1, total / 100)   // report at most ~100 progress ticks
        result.enumerateObjects { asset, index, _ in
            let mtime = (asset.modificationDate ?? asset.creationDate ?? .distantPast)
                .timeIntervalSince1970
            let ctime = (asset.creationDate ?? .distantPast).timeIntervalSince1970
            let resources = PHAssetResource.assetResources(for: asset)
            let name = resources.first?.originalFilename ?? asset.localIdentifier
            let byteSize = fileSize(of: resources)
            assets.append(ScanItem(
                id: asset.localIdentifier,
                source: .asset(asset.localIdentifier),
                name: name,
                mtime: mtime,
                creationDate: ctime,
                byteSize: byteSize,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                // Pixel count, not byte size: iCloud-only originals often report
                // no local size, and byte-identical photos always share dimensions.
                token: Int64(asset.pixelWidth) * Int64(asset.pixelHeight)
            ))
            if index % step == 0 || index == total - 1 {
                progress(total > 0 ? Double(index + 1) / Double(total) : 1)
            }
        }
        return assets
    }

    /// User-visible albums (smart albums + user collections) with non-zero counts.
    nonisolated static func fetchAlbums() -> [AlbumOption] {
        var out: [AlbumOption] = []

        func collect(_ result: PHFetchResult<PHAssetCollection>) {
            result.enumerateObjects { collection, _, _ in
                let opts = PHFetchOptions()
                opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                let count = PHAsset.fetchAssets(in: collection, options: opts).count
                guard count > 0, let title = collection.localizedTitle else { return }
                out.append(AlbumOption(id: collection.localIdentifier, title: title, count: count))
            }
        }

        collect(PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil))
        collect(PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil))
        return out.sorted { $0.count > $1.count }
    }

    // MARK: Hashing (identical detection)

    /// SHA-256 of the primary image resource, streamed in chunks so large originals
    /// never sit fully in memory. Local-only: iCloud-only originals are skipped to
    /// keep the "everything stays on device" guarantee. Returns nil if unavailable.
    nonisolated static func sha256(forAssetID id: String) async -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = primaryImageResource(for: asset) else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        var hasher = SHA256()
        let manager = PHAssetResourceManager.default()

        return await withCheckedContinuation { continuation in
            manager.requestData(for: resource, options: options) { chunk in
                hasher.update(data: chunk)
            } completionHandler: { error in
                if error != nil {
                    continuation.resume(returning: nil)
                } else {
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: digest)
                }
            }
        }
    }

    nonisolated private static func primaryImageResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
    }

    /// On-disk byte size of an asset's primary image resource. `fileSize` isn't part
    /// of the public `PHAssetResource` API, so we read it via KVC; returns 0 when the
    /// key is missing (e.g. iCloud-only originals that report no local size).
    nonisolated private static func fileSize(of resources: [PHAssetResource]) -> Int64 {
        let resource = resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
        return (resource?.value(forKey: "fileSize") as? Int64) ?? 0
    }

    // MARK: Image requests (similarity + thumbnails)

    /// A downscaled CGImage suitable for Vision feature-print generation. Local-only.
    nonisolated static func cgImage(forAssetID id: String, maxPixel: CGFloat) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let image = await requestPlatformImage(
            for: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            contentMode: .aspectFit,
            allowNetwork: false,
            deliveryMode: .highQualityFormat
        )
        return image?.cgImage
    }

    /// Progressively delivers images for the long-press preview: Photos yields a
    /// fast, low-resolution version first (usually from cache, near-instant) and
    /// then the full-quality image once it's ready. Consuming each yield in turn
    /// means the user sees a blurry placeholder immediately instead of a spinner —
    /// or, worse, the previously shown photo — while the real one loads. Allows
    /// iCloud so the full photo can be shown even if the original isn't local.
    nonisolated static func previewImages(forAssetID id: String, maxPixel: CGFloat) -> AsyncStream<PlatformImage> {
        AsyncStream { continuation in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
            else { continuation.finish(); return }

            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic   // degraded delivery first, then full
            options.resizeMode = .fast

            let manager = PHImageManager.default()
            let requestID = manager.requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let image { continuation.yield(image) }
                // Opportunistic mode calls back at least twice (degraded → full).
                // Finish once the final image arrives, or on cancel/error.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                if !degraded || cancelled || failed {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                manager.cancelImageRequest(requestID)
            }
        }
    }

    /// A square thumbnail for the results list. Allows iCloud so previews still show.
    nonisolated static func thumbnail(forAssetID id: String, pointSize: CGFloat, scale: CGFloat) async -> PlatformImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let px = pointSize * scale
        return await requestPlatformImage(
            for: asset,
            targetSize: CGSize(width: px, height: px),
            contentMode: .aspectFill,
            allowNetwork: true,
            deliveryMode: .opportunistic
        )
    }

    nonisolated private static func requestPlatformImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        allowNetwork: Bool,
        deliveryMode: PHImageRequestOptionsDeliveryMode
    ) async -> PlatformImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        // We only want a single, final delivery for our async/await call site.
        options.isSynchronous = false

        let manager = PHImageManager.default()
        return await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                // opportunistic mode can call back twice (degraded then full); only
                // resume once, on the final non-degraded delivery.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                if !resumed {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    // MARK: Deletion

    /// Moves the given assets to "Recently Deleted". iOS shows its own confirmation
    /// sheet; the user can restore from Recently Deleted for ~30 days.
    static func deleteAssets(ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
