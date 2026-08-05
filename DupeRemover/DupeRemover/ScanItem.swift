import Foundation

// What a scan can look at. Both cases carry only a Sendable identifier: the
// PHAsset is re-fetched inside whichever task needs it, never handed across a
// task boundary, because it isn't Sendable and pretending otherwise is exactly
// the kind of assumption that bites under the parallel comparison below.
nonisolated enum ItemSource: Hashable, Sendable {
    case file(URL)
    case asset(String)      // PHAsset.localIdentifier
}

// One scannable image, from either source. A cheap Sendable snapshot: enough to
// group, cache, and display without touching Photos or the disk again.
nonisolated struct ScanItem: Identifiable, Hashable, Sendable {
    let id: String          // file path or PHAsset.localIdentifier
    let source: ItemSource
    let name: String
    let mtime: Double       // modification (or creation) date as epoch seconds
    let creationDate: Double
    let byteSize: Int64     // 0 when unknown (iCloud-only originals)
    let pixelWidth: Int     // 0 for files — never decoded just to measure
    let pixelHeight: Int
    // Cheap collision key for identical-detection and the cache's change token:
    // pixel count for assets, byte size for files. See CacheEntry.token.
    let token: Int64
    // Whether the original is on this device. False for iCloud-only assets, whose
    // bytes the scan deliberately will not download — so hashing them can only
    // fail. Always true for files.
    var isLocal: Bool = true

    var localURL: URL? {
        if case .file(let url) = source { return url }
        return nil
    }
}

nonisolated enum MatchMode {
    case identical
    case similar
}

nonisolated struct DuplicateGroup: Identifiable {
    let id: String
    var items: [ScanItem]
    var mode: MatchMode
}
