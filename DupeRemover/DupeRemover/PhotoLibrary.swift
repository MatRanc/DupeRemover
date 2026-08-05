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

/// Where a library photo actually lives, for the row's Info action.
nonisolated struct AssetPlacement: Sendable {
    let source: String
    let albums: [String]
}

/// What a library scan covers. Default is everything; the rest narrow the fetch.
nonisolated enum ScanScope: Hashable, Sendable {
    case entireLibrary
    case personal           // your own photos, including anything synced from a Mac
    case shared             // an iCloud Shared Library or shared albums
    case album(String)      // PHAssetCollection.localIdentifier
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

    /// Photos you own. iTunes-synced assets sit here rather than under "shared":
    /// they came off your own Mac, nobody else contributed them.
    nonisolated static let personalSources: PHAssetSourceType = [.typeUserLibrary, .typeiTunesSynced]
    nonisolated static let sharedSources: PHAssetSourceType = [.typeCloudShared]
    nonisolated static let allSources: PHAssetSourceType = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]

    /// Images, newest first, from the named asset sources.
    ///
    /// `includeAssetSourceTypes` matters more than it looks: left unset, a
    /// library-wide `fetchAssets(with:)` returns only `typeUserLibrary` assets. On a
    /// Mac signed into an iCloud Shared Library every asset is `typeCloudShared`
    /// instead, so the fetch came back completely empty — "No photos found." — while
    /// the same photos counted fine through albums, which don't apply that filter.
    nonisolated static func imageFetchOptions(sources: PHAssetSourceType = allSources) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = sources
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    /// How many images each source holds. Both rows only earn their place in the
    /// scope sheet when a library actually mixes the two.
    nonisolated static func sourceCounts() -> (personal: Int, shared: Int) {
        (PHAsset.fetchAssets(with: imageFetchOptions(sources: personalSources)).count,
         PHAsset.fetchAssets(with: imageFetchOptions(sources: sharedSources)).count)
    }

    /// All image assets within a scope. Runs off the main actor.
    /// `progress` is called with a 0...1 fraction as enumeration advances — reading
    /// per-asset resources (filename, size) is the slow part for large libraries,
    /// so this drives a real progress bar instead of an indeterminate spinner.
    nonisolated static func fetchImageAssets(
        scope: ScanScope,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) -> [ScanItem] {
        let sources: PHAssetSourceType
        switch scope {
        case .personal: sources = personalSources
        case .shared: sources = sharedSources
        case .entireLibrary, .album: sources = allSources
        }
        let options = imageFetchOptions(sources: sources)

        let result: PHFetchResult<PHAsset>
        if case .album(let albumID) = scope,
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
        result.enumerateObjects { asset, index, stop in
            // Reading resources for tens of thousands of assets is the longest
            // uninterruptible stretch of a scan unless it checks.
            if Task.isCancelled {
                stop.pointee = true
                return
            }
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
                token: Int64(asset.pixelWidth) * Int64(asset.pixelHeight),
                isLocal: isLocallyAvailable(resources)
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

    /// Where one photo lives: the library it came from and the albums holding it.
    /// Looked up for a single asset on demand, which is the only reason the
    /// per-asset album fetch is affordable at all.
    nonisolated static func placement(forAssetID id: String) -> AssetPlacement? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }

        let source: String
        if asset.sourceType.contains(.typeCloudShared) {
            source = "Shared library"
        } else if asset.sourceType.contains(.typeiTunesSynced) {
            source = "Synced from a computer"
        } else {
            source = "Personal library"
        }

        // User albums only. Smart albums would add "Recents" to every single photo.
        var albums: [String] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { collection, _, _ in
                if let title = collection.localizedTitle { albums.append(title) }
            }
        return AssetPlacement(source: source, albums: albums.sorted())
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
        primaryImageResource(in: PHAssetResource.assetResources(for: asset))
    }

    nonisolated private static func primaryImageResource(in resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
    }

    /// On-disk byte size of an asset's primary image resource. `fileSize` isn't part
    /// of the public `PHAssetResource` API, so we read it via KVC; returns 0 when the
    /// key is missing (e.g. iCloud-only originals that report no local size).
    nonisolated private static func fileSize(of resources: [PHAssetResource]) -> Int64 {
        (primaryImageResource(in: resources)?.value(forKey: "fileSize") as? Int64) ?? 0
    }

    /// Whether the original bytes are on this device. Also not public API — same KVC
    /// route as `fileSize`. A missing key reads as available, so the worst an OS
    /// change can do is put us back to today's behaviour of finding out by failing.
    nonisolated private static func isLocallyAvailable(_ resources: [PHAssetResource]) -> Bool {
        (primaryImageResource(in: resources)?.value(forKey: "locallyAvailable") as? Bool) ?? true
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
