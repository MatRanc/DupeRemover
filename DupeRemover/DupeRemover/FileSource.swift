import Foundation
import CryptoKit
import ImageIO
import QuickLookThumbnailing

nonisolated let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"
]

/// The local-folder counterpart to `PhotoLibrary`. Same four jobs — enumerate,
/// hash, produce a Vision-sized image, produce a thumbnail — so `Scanner` can
/// switch on `ItemSource` and otherwise not care where an item came from.
///
/// Security-scoped access is the caller's business: the folder URLs come from a
/// picker and the scan touches them long after enumeration, so the claim has to
/// outlive any single call here (see `ScanViewModel.claimAccess`).
enum FileSource {

    /// Every image file under `folders`, recursively. Byte size is the change
    /// token; dimensions are left at 0 rather than decoding every file to learn
    /// them (the scan never needs them, only the row subtitle would).
    nonisolated static func enumerate(_ folders: [URL]) -> [ScanItem] {
        var items: [ScanItem] = []
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                // Walking a deep tree can run for a while; the caller checks
                // cancellation again as soon as this returns.
                if Task.isCancelled { return items }
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let r = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .isRegularFileKey, .contentModificationDateKey, .creationDateKey,
                ])
                guard r?.isRegularFile == true,
                      let size = r?.fileSize,
                      let mdate = r?.contentModificationDate else { continue }
                items.append(ScanItem(
                    id: url.path,
                    source: .file(url),
                    name: url.lastPathComponent,
                    mtime: mdate.timeIntervalSince1970,
                    creationDate: (r?.creationDate ?? mdate).timeIntervalSince1970,
                    byteSize: Int64(size),
                    pixelWidth: 0,
                    pixelHeight: 0,
                    token: Int64(size)
                ))
            }
        }
        return items
    }

    /// Streamed in chunks so a large original never sits in memory whole.
    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Decoded straight to `maxPixel` on the long edge by ImageIO — never the full
    /// image. This deliberately matches the size the Photos path hands Vision, so a
    /// print made from a file is comparable with one made from an asset.
    nonisolated static func cgImage(at url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    nonisolated static func thumbnail(at url: URL, pointSize: CGFloat, scale: CGFloat) async -> PlatformImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pointSize, height: pointSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        #if os(iOS)
        return rep?.uiImage
        #else
        return rep?.nsImage
        #endif
    }
}
