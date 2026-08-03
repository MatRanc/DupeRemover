import Foundation
import Combine
import CryptoKit
import AppKit
import Vision
import Photos

nonisolated let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"
]

// Default distance below which two photos are considered "similar" (Vision feature
// print). 0.0 = identical embeddings; ~0.2 = visually near-duplicate; 0.5+ = different
// scenes. Exposed as a slider in the UI so users can tune strictness.
nonisolated let defaultSimilarityPercent: Double = 20.0

nonisolated enum MatchMode {
    case identical
    case similar
}

// PHAsset is treated as an immutable snapshot from the Photos framework, safe to pass
// across actors in practice even though it isn't declared Sendable upstream.
nonisolated enum ItemSource: @unchecked Sendable, Hashable {
    case file(URL)
    case asset(PHAsset)
}

nonisolated struct ScanItem: Identifiable, Hashable, Sendable {
    let id: String // URL path or PHAsset.localIdentifier
    let source: ItemSource
    let name: String
    let size: Int64
    let mtime: Double

    var localURL: URL? {
        if case .file(let url) = source { return url }
        return nil
    }
}

nonisolated struct DuplicateGroup: Identifiable {
    let id: String
    var files: [ScanItem]
    var mode: MatchMode
}

nonisolated func sha256(of item: ScanItem) async -> String? {
    switch item.source {
    case .file(let url):
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    case .asset(let asset):
        guard let data = await requestImageData(for: asset) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated func computeFeaturePrint(for item: ScanItem) async -> VNFeaturePrintObservation? {
    let request = VNGenerateImageFeaturePrintRequest()
    switch item.source {
    case .file(let url):
        let handler = VNImageRequestHandler(url: url, options: [:])
        try? handler.perform([request])
    case .asset(let asset):
        guard let data = await requestImageData(for: asset) else { return nil }
        let handler = VNImageRequestHandler(data: data, options: [:])
        try? handler.perform([request])
    }
    return request.results?.first
}

nonisolated func requestImageData(for asset: PHAsset) async -> Data? {
    await withCheckedContinuation { continuation in
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            continuation.resume(returning: data)
        }
    }
}

nonisolated func archiveFeaturePrint(_ observation: VNFeaturePrintObservation) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
}

nonisolated func unarchiveFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
    try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
}

nonisolated func enumerateFiles(in folders: [URL]) -> [ScanItem] {
    var items: [ScanItem] = []
    for folder in folders {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }
        for case let url as URL in enumerator {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let r = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
            guard r?.isRegularFile == true,
                  let size = r?.fileSize,
                  let mdate = r?.contentModificationDate else { continue }
            items.append(ScanItem(
                id: url.path,
                source: .file(url),
                name: url.lastPathComponent,
                size: Int64(size),
                mtime: mdate.timeIntervalSince1970
            ))
        }
    }
    return items
}

nonisolated func requestPhotosAuthorization() async -> Bool {
    let status = await withCheckedContinuation { continuation in
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
    }
    return status == .authorized || status == .limited
}

nonisolated func enumeratePhotoLibraryAssets() -> [ScanItem] {
    let result = PHAsset.fetchAssets(with: .image, options: nil)
    var items: [ScanItem] = []
    result.enumerateObjects { asset, _, _ in
        // fileSize has no public accessor on PHAssetResource; KVC is the standard
        // workaround to estimate size without downloading the asset.
        let resource = PHAssetResource.assetResources(for: asset).first
        let name = resource?.originalFilename ?? asset.localIdentifier
        let size = (resource?.value(forKey: "fileSize") as? Int64) ?? 0
        items.append(ScanItem(
            id: asset.localIdentifier,
            source: .asset(asset),
            name: name,
            size: size,
            mtime: (asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0
        ))
    }
    return items
}

nonisolated final class UnionFind {
    private var parent: [Int]
    init(count: Int) { parent = Array(0..<count) }

    func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}

nonisolated enum ScanSource {
    case folder
    case photosLibrary
}

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    @Published var statusText = "Choose a folder to scan."
    @Published var selected: Set<String> = []
    @Published var matchSimilar = false
    @Published var similarityPercent: Double = defaultSimilarityPercent
    @Published var cacheEntries = 0
    @Published var cacheSize: Int64 = 0
    @Published var scanSource: ScanSource = .folder
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScannedFolders: [URL] = []

    private let cache = CacheStore()

    init() {
        Task { await refreshCacheStats() }
    }

    func refreshCacheStats() async {
        cacheEntries = await cache.entryCount()
        cacheSize = await cache.diskSize()
    }

    func clearCache() async {
        await cache.clear()
        await refreshCacheStats()
        statusText = "Cache cleared."
    }

    func chooseFoldersAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await scanFolders(urls) }
    }

    func scanFolders(_ folders: [URL]) async {
        scanSource = .folder
        lastScannedFolders = folders
        isScanning = true
        groups = []
        selected = []
        statusText = "Enumerating files…"

        let items = await Task.detached(priority: .userInitiated) {
            enumerateFiles(in: folders)
        }.value

        await runScan(items: items)
    }

    func scanPhotosLibrary() {
        scanSource = .photosLibrary
        Task {
            isScanning = true
            groups = []
            selected = []
            statusText = "Requesting Photos access…"

            guard await requestPhotosAuthorization() else {
                statusText = "Photos access denied."
                isScanning = false
                return
            }

            statusText = "Enumerating photos…"
            let items = await Task.detached(priority: .userInitiated) {
                enumeratePhotoLibraryAssets()
            }.value

            await runScan(items: items)
        }
    }

    func rescan() {
        guard hasScanned, !isScanning else { return }
        switch scanSource {
        case .folder:
            guard !lastScannedFolders.isEmpty else { return }
            Task { await scanFolders(lastScannedFolders) }
        case .photosLibrary:
            scanPhotosLibrary()
        }
    }

    private func runScan(items allFiles: [ScanItem]) async {
        hasScanned = true

        guard !allFiles.isEmpty else {
            statusText = "No image files found."
            isScanning = false
            return
        }

        let uf = UnionFind(count: allFiles.count)
        var hashByIndex: [Int: String] = [:]

        // Step 1: identical detection by SHA-256, only for size collisions.
        var bySize: [Int64: [Int]] = [:]
        for (i, f) in allFiles.enumerated() { bySize[f.size, default: []].append(i) }
        let candidateIndexes = bySize.values.filter { $0.count > 1 }.flatMap { $0 }

        statusText = "Hashing \(candidateIndexes.count) of \(allFiles.count) photos…"

        var toHash: [Int] = []
        for i in candidateIndexes {
            let f = allFiles[i]
            if let entry = await cache.get(path: f.id, mtime: f.mtime, size: f.size),
               let h = entry.sha256 {
                hashByIndex[i] = h
            } else {
                toHash.append(i)
            }
        }

        if !toHash.isEmpty {
            let computed: [(Int, String)] = await Task.detached(priority: .userInitiated) {
                var out: [(Int, String)] = []
                for i in toHash {
                    if let h = await sha256(of: allFiles[i]) {
                        out.append((i, h))
                    }
                }
                return out
            }.value

            for (i, h) in computed {
                hashByIndex[i] = h
                let f = allFiles[i]
                await cache.setHash(path: f.id, mtime: f.mtime, size: f.size, sha256: h)
            }
        }

        var byHash: [String: [Int]] = [:]
        for (i, h) in hashByIndex { byHash[h, default: []].append(i) }
        for (_, idxs) in byHash where idxs.count > 1 {
            for k in 1..<idxs.count { uf.union(idxs[0], idxs[k]) }
        }

        // Step 2: optional perceptual similarity via Vision feature prints.
        if matchSimilar {
            statusText = "Loading cached visual fingerprints…"

            var printsData: [Int: Data] = [:]
            var missing: [Int] = []
            for (i, f) in allFiles.enumerated() {
                if let entry = await cache.get(path: f.id, mtime: f.mtime, size: f.size),
                   let data = entry.featurePrintData {
                    printsData[i] = data
                } else {
                    missing.append(i)
                }
            }

            if !missing.isEmpty {
                let total = missing.count
                statusText = "Analyzing 0/\(total) photos…"
                var done = 0
                var nextIndex = 0
                var newlyComputed: [(Int, Data)] = []

                // Vision saturates the Neural Engine with very few concurrent
                // requests, so cap parallelism. Beyond ~4 we just multiply file
                // I/O contention without speeding up inference.
                let maxConcurrent = 4

                await withTaskGroup(of: (Int, Data?).self) { group in
                    func scheduleNext() {
                        guard nextIndex < missing.count else { return }
                        let i = missing[nextIndex]
                        let item = allFiles[i]
                        nextIndex += 1
                        group.addTask {
                            let obs = await computeFeaturePrint(for: item)
                            return (i, obs.flatMap(archiveFeaturePrint))
                        }
                    }

                    for _ in 0..<min(maxConcurrent, total) { scheduleNext() }

                    while let (i, data) = await group.next() {
                        if let data = data {
                            printsData[i] = data
                            newlyComputed.append((i, data))
                        }
                        done += 1
                        let name = allFiles[i].name
                        statusText = "Analyzing \(done)/\(total) photos · \(name)"
                        scheduleNext()
                    }
                }

                // Persist new feature prints to cache once analysis is done.
                for (i, data) in newlyComputed {
                    let f = allFiles[i]
                    await cache.setFeaturePrint(
                        path: f.id, mtime: f.mtime, size: f.size, data: data
                    )
                }
            }

            statusText = "Comparing \(printsData.count) fingerprints…"

            // Heavy work runs off the main thread: unarchive each feature print
            // and do the O(n²) pairwise distance check, returning only the pairs
            // whose distance is below the similarity threshold.
            let dataSnapshot = printsData
            let threshold = Float(similarityPercent / 100.0)
            let pairs: [(Int, Int)] = await Task.detached(priority: .userInitiated) {
                var prints: [Int: VNFeaturePrintObservation] = [:]
                for (i, data) in dataSnapshot {
                    if let obs = unarchiveFeaturePrint(data) { prints[i] = obs }
                }
                let indexes = Array(prints.keys).sorted()
                var matches: [(Int, Int)] = []
                for ii in 0..<indexes.count {
                    let i = indexes[ii]
                    guard let pi = prints[i] else { continue }
                    for jj in (ii + 1)..<indexes.count {
                        let j = indexes[jj]
                        guard let pj = prints[j] else { continue }
                        var dist: Float = 0
                        do {
                            try pi.computeDistance(&dist, to: pj)
                            if dist < threshold {
                                matches.append((i, j))
                            }
                        } catch { }
                    }
                }
                return matches
            }.value

            for (i, j) in pairs { uf.union(i, j) }
        }

        // Step 3: build groups.
        var clusters: [Int: [Int]] = [:]
        for i in 0..<allFiles.count {
            clusters[uf.find(i), default: []].append(i)
        }

        let resultGroups: [DuplicateGroup] = clusters.values.compactMap { idxs in
            guard idxs.count > 1 else { return nil }
            let files = idxs.map { allFiles[$0] }
            let theseHashes = Set(idxs.compactMap { hashByIndex[$0] })
            let allHashed = idxs.allSatisfy { hashByIndex[$0] != nil }
            let mode: MatchMode = (allHashed && theseHashes.count == 1) ? .identical : .similar
            return DuplicateGroup(
                id: UUID().uuidString,
                files: files.sorted { $0.id < $1.id },
                mode: mode
            )
        }.sorted { a, b in
            if a.mode != b.mode { return a.mode == .identical }
            return a.files.count > b.files.count
        }

        groups = resultGroups
        let dupCount = resultGroups.reduce(0) { $0 + $1.files.count - 1 }
        let identicalCount = resultGroups.filter { $0.mode == .identical }.count
        let similarCount = resultGroups.filter { $0.mode == .similar }.count
        if resultGroups.isEmpty {
            statusText = "No duplicates found across \(allFiles.count) photos."
        } else {
            var parts: [String] = []
            if identicalCount > 0 { parts.append("\(identicalCount) identical") }
            if similarCount > 0 { parts.append("\(similarCount) similar") }
            statusText = "\(parts.joined(separator: " · ")) groups · \(dupCount) extras of \(allFiles.count) photos."
        }

        await refreshCacheStats()
        isScanning = false
    }

    func toggle(_ item: ScanItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func selectAllButFirstInEveryGroup() {
        var next: Set<String> = []
        for g in groups {
            for f in g.files.dropFirst() { next.insert(f.id) }
        }
        selected = next
    }

    func clearSelection() {
        selected = []
    }

    func trashSelected() {
        let items = groups.flatMap { $0.files }.filter { selected.contains($0.id) }
        var localURLs: [URL] = []
        var assets: [PHAsset] = []
        for item in items {
            switch item.source {
            case .file(let url): localURLs.append(url)
            case .asset(let asset): assets.append(asset)
            }
        }

        var trashedIDs: Set<String> = []
        var failed = 0

        for url in localURLs {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                trashedIDs.insert(url.path)
            } catch {
                failed += 1
            }
        }

        guard !assets.isEmpty else {
            finishTrashing(trashedIDs: trashedIDs, failed: failed)
            return
        }

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }, completionHandler: { success, _ in
            let assetTrashedIDs = success ? Set(assets.map { $0.localIdentifier }) : []
            let assetFailed = success ? 0 : assets.count
            Task { @MainActor in
                self.finishTrashing(
                    trashedIDs: trashedIDs.union(assetTrashedIDs),
                    failed: failed + assetFailed
                )
            }
        })
    }

    private func finishTrashing(trashedIDs: Set<String>, failed: Int) {
        groups = groups.compactMap { g in
            let remaining = g.files.filter { !trashedIDs.contains($0.id) }
            return remaining.count > 1 ? DuplicateGroup(id: g.id, files: remaining, mode: g.mode) : nil
        }
        selected = []
        statusText = failed == 0
            ? "Moved \(trashedIDs.count) to Trash."
            : "Moved \(trashedIDs.count) to Trash · \(failed) failed."
    }
}

nonisolated func formatBytes(_ bytes: Int64) -> String {
    let bcf = ByteCountFormatter()
    bcf.allowedUnits = [.useKB, .useMB, .useGB]
    bcf.countStyle = .file
    return bcf.string(fromByteCount: bytes)
}
