import Foundation
import Combine
import Vision
import UIKit
import Photos

// Default distance below which two photos are considered "similar" (Vision feature
// print). 0.0 = identical embeddings; ~0.2 = visually near-duplicate; 0.5+ =
// different scenes. Exposed as a slider so users can tune strictness.
nonisolated let defaultSimilarityPercent: Double = 20.0

// Longest edge, in pixels, of the image handed to Vision. Vision downsizes
// internally anyway; 448px keeps feature prints stable while cutting decode cost.
nonisolated let visionInputPixel: CGFloat = 448

nonisolated func computeFeaturePrint(from cgImage: CGImage) -> VNFeaturePrintObservation? {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])
    return request.results?.first
}

nonisolated func archiveFeaturePrint(_ observation: VNFeaturePrintObservation) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
}

nonisolated func unarchiveFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
    try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
}

// The revision this OS produces. Prints from an older revision are not comparable
// with new ones, so an OS upgrade must invalidate them.
nonisolated let currentFeaturePrintRevision: Int = VNGenerateImageFeaturePrintRequest().revision

nonisolated struct ArchivedPrint: Sendable {
    let data: Data
    let revision: Int
}

/// Holds the archived prints so the compare task can release them once they are
/// unarchived. A plain captured value would stay pinned for the whole comparison.
nonisolated final class FeaturePrintBox: @unchecked Sendable {
    var value: [Int: Data]
    init(_ value: [Int: Data]) { self.value = value }
}

/// The unarchived prints, shared read-only across comparison workers.
///
/// `@unchecked` because `VNFeaturePrintObservation` is not `Sendable`. The sharing
/// is safe here on two counts: both arrays are fully built before any worker
/// starts and never mutated afterwards, and `computeDistance` only reads the two
/// observations it is given. If Vision ever mutated an observation on first
/// comparison this assumption would break — it is the one unproven thing in the
/// parallel path.
nonisolated final class PrintTable: @unchecked Sendable {
    let ids: [Int]
    let prints: [VNFeaturePrintObservation]
    var count: Int { prints.count }

    init(ids: [Int], prints: [VNFeaturePrintObservation]) {
        self.ids = ids
        self.prints = prints
    }
}

/// Shared state for the parallel comparison. Workers own their own match buffers
/// and merge once at the end, so the lock is touched per row-batch, not per pair.
nonisolated final class CompareState: @unchecked Sendable {
    private let lock = NSLock()
    private var donePairs = 0
    private var lastReported = 0.0
    private var merged: [(Int, Int)] = []

    var matches: [(Int, Int)] {
        lock.lock(); defer { lock.unlock() }
        return merged
    }

    func merge(_ local: [(Int, Int)]) {
        lock.lock(); defer { lock.unlock() }
        merged.append(contentsOf: local)
    }

    /// Records progress, returning a fraction only when it moved enough to be worth
    /// a UI update — otherwise ~100 workers' worth of yields flood the stream.
    func advance(by pairs: Int, of total: Int) -> Double? {
        guard pairs > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        donePairs += pairs
        let frac = Double(donePairs) / Double(total)
        guard frac - lastReported >= 0.01 else { return nil }
        lastReported = frac
        return frac
    }
}

/// A cached print that is safe to compare against freshly computed ones.
///
/// Entries written before revisions were tracked carry none, so rather than
/// recompute every one of them — hours, on a large library — unarchive to read the
/// revision it was actually made with. That costs microseconds against the ~50ms a
/// recompute would need.
nonisolated func comparableFeaturePrint(_ entry: CacheEntry, revision: Int) -> Data? {
    if entry.featurePrintRevision != nil { return entry.featurePrint(revision: revision) }
    guard let data = entry.featurePrintData,
          let obs = unarchiveFeaturePrint(data),
          obs.requestRevision == revision else { return nil }
    return data
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

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    // 0...1 drives a determinate progress bar; nil means indeterminate (spinner).
    @Published var progress: Double? = nil
    @Published var statusText = "Tap Scan to find duplicates in your library."
    // "Step 2 of 4 · Hashing" — which phase of the scan is running.
    @Published var stepText = ""
    // "about 2m 30s left", nil until enough work is done to extrapolate.
    @Published var etaText: String?
    // Extra reassurance shown only on the slow phases.
    @Published var hintText: String?
    @Published var selected: Set<String> = []
    @Published var matchSimilar = false
    @Published var similarityPercent: Double = defaultSimilarityPercent
    @Published var cacheEntries = 0
    @Published var cacheSize: Int64 = 0

    // nil = entire library. Otherwise scoped to one album.
    @Published var selectedAlbumID: String? = nil
    @Published var selectedAlbumTitle: String? = nil
    @Published var albums: [AlbumOption] = []

    @Published var authStatus = PhotoLibrary.authorizationStatus

    private let cache = CacheStore()

    init() {
        Task { await refreshCacheStats() }
    }

    var hasFullOrLimitedAccess: Bool {
        authStatus == .authorized || authStatus == .limited
    }

    func requestAccess() async {
        authStatus = await PhotoLibrary.requestAuthorization()
        if hasFullOrLimitedAccess { await loadAlbums() }
    }

    func refreshAuthStatus() {
        authStatus = PhotoLibrary.authorizationStatus
    }

    func loadAlbums() async {
        albums = await Task.detached(priority: .userInitiated) {
            PhotoLibrary.fetchAlbums()
        }.value
    }

    func selectAlbum(_ album: AlbumOption?) {
        selectedAlbumID = album?.id
        selectedAlbumTitle = album?.title
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

    func scan() async {
        guard hasFullOrLimitedAccess else { return }
        isScanning = true
        groups = []
        selected = []
        progress = 0
        etaText = nil
        hintText = nil

        // Scanning is long and touch-free, so the display would otherwise sleep and
        // suspend the app mid-scan.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        let totalSteps = matchSimilar ? 4 : 2
        func beginStep(_ n: Int, _ name: String) {
            stepText = "Step \(n) of \(totalSteps) · \(name)"
            etaText = nil
            hintText = nil
        }

        beginStep(1, "Reading library")
        statusText = "Reading your library…"

        // Read assets off the main actor, streaming progress back so the UI shows a
        // real progress bar (reading per-asset resources is slow on big libraries).
        let albumID = selectedAlbumID
        let readStart = Date()
        let (progressStream, progressCont) = AsyncStream<Double>.makeStream()
        let fetchTask = Task.detached(priority: .userInitiated) { () -> [PhotoAsset] in
            let assets = PhotoLibrary.fetchImageAssets(inAlbum: albumID) { frac in
                progressCont.yield(frac)
            }
            progressCont.finish()
            return assets
        }
        for await frac in progressStream {
            progress = frac
            statusText = "Reading your library… \(Int(frac * 100))%"
            etaText = remainingTimeText(start: readStart, fraction: frac)
        }
        let allAssets = await fetchTask.value
        progress = nil
        etaText = nil

        guard !allAssets.isEmpty else {
            statusText = "No photos found\(selectedAlbumTitle.map { " in \($0)" } ?? "")."
            stepText = ""
            isScanning = false
            return
        }

        let uf = UnionFind(count: allAssets.count)
        var hashByIndex: [Int: String] = [:]

        // Step 1: identical detection by SHA-256, only for pixel-dimension
        // collisions (byte-identical files always share their dimensions, so this
        // skips hashing the vast majority of one-of-a-kind photos).
        var byDims: [Int64: [Int]] = [:]
        for (i, a) in allAssets.enumerated() { byDims[a.pixelCount, default: []].append(i) }
        let candidateIndexes = byDims.values.filter { $0.count > 1 }.flatMap { $0 }

        beginStep(2, "Finding identical photos")
        statusText = "Hashing \(candidateIndexes.count) of \(allAssets.count) photos…"

        var toHash: [Int] = []
        for i in candidateIndexes {
            let a = allAssets[i]
            if let entry = await cache.get(id: a.id, mtime: a.mtime, pixelCount: a.pixelCount),
               let h = entry.sha256 {
                hashByIndex[i] = h
            } else {
                toHash.append(i)
            }
        }

        if !toHash.isEmpty {
            progress = 0
            var done = 0
            let hashStart = Date()
            await withTaskGroupLimited(items: toHash, maxConcurrent: 4) { i in
                let h = await PhotoLibrary.sha256(forAssetID: allAssets[i].id)
                return (i, h)
            } onResult: { result in
                let (i, h) = result
                done += 1
                if let h {
                    hashByIndex[i] = h
                    let a = allAssets[i]
                    await self.cache.setHash(id: a.id, mtime: a.mtime, pixelCount: a.pixelCount, sha256: h)
                }
                self.progress = Double(done) / Double(toHash.count)
                self.statusText = "Hashing \(done)/\(toHash.count) photos…"
                self.etaText = remainingTimeText(
                    start: hashStart, fraction: Double(done) / Double(toHash.count))
            }
            await cache.flushNow()
            progress = nil
            etaText = nil
        }

        var byHash: [String: [Int]] = [:]
        for (i, h) in hashByIndex { byHash[h, default: []].append(i) }
        for (_, idxs) in byHash where idxs.count > 1 {
            for k in 1..<idxs.count { uf.union(idxs[0], idxs[k]) }
        }

        // Step 2: optional perceptual similarity via Vision feature prints.
        if matchSimilar {
            beginStep(3, "Analyzing photos")
            statusText = "Loading cached visual fingerprints…"

            var printsData: [Int: Data] = [:]
            var missing: [Int] = []
            for (i, a) in allAssets.enumerated() {
                if let entry = await cache.get(id: a.id, mtime: a.mtime, pixelCount: a.pixelCount),
                   let data = comparableFeaturePrint(entry, revision: currentFeaturePrintRevision) {
                    printsData[i] = data
                } else {
                    missing.append(i)
                }
            }

            if !missing.isEmpty {
                let total = missing.count
                progress = 0
                statusText = "Analyzing 0/\(total) photos…"
                hintText = "This may take a while. Fingerprints are cached, so future scans are much faster."
                var done = 0
                let analyzeStart = Date()
                // Vision saturates the Neural Engine with very few concurrent
                // requests, so cap parallelism. Beyond ~4 we just multiply image
                // request contention without speeding up inference.
                await withTaskGroupLimited(items: missing, maxConcurrent: 4) { i -> (Int, ArchivedPrint?) in
                    let id = allAssets[i].id
                    guard let cg = await PhotoLibrary.cgImage(forAssetID: id, maxPixel: visionInputPixel),
                          let obs = computeFeaturePrint(from: cg),
                          let data = archiveFeaturePrint(obs) else { return (i, nil) }
                    return (i, ArchivedPrint(data: data, revision: obs.requestRevision))
                } onResult: { result in
                    let (i, archived) = result
                    done += 1
                    if let archived {
                        printsData[i] = archived.data
                        let a = allAssets[i]
                        await self.cache.setFeaturePrint(
                            id: a.id, mtime: a.mtime, pixelCount: a.pixelCount,
                            data: archived.data, revision: archived.revision)
                    }
                    self.progress = Double(done) / Double(total)
                    self.statusText = "Analyzing \(done)/\(total) photos…"
                    self.etaText = remainingTimeText(
                        start: analyzeStart, fraction: Double(done) / Double(total))
                }
                await cache.flushNow()
                progress = nil
                etaText = nil
            }

            beginStep(4, "Comparing photos")
            progress = 0
            statusText = "Comparing \(printsData.count) fingerprints…"
            hintText = "This may take a while on large libraries."

            // Heavy work off the main actor: unarchive each feature print and do the
            // O(n²) pairwise distance check, returning only the below-threshold pairs.
            // Progress is streamed back by fraction of pairs compared (the work is
            // triangular, so a simple outer-index fraction would feel non-linear).
            let box = FeaturePrintBox(printsData)
            printsData = [:]
            let threshold = Float(similarityPercent / 100.0)
            let compareStart = Date()
            let (cmpStream, cmpCont) = AsyncStream<Double>.makeStream()
            let compareTask = Task.detached(priority: .userInitiated) { () -> [(Int, Int)] in
                // Flat parallel arrays, not a dictionary: the inner loop runs ~n²/2
                // times, so a keyed lookup there costs a billion hash probes to learn
                // nothing an array index doesn't already give.
                var ids: [Int] = []
                var prints: [VNFeaturePrintObservation] = []
                ids.reserveCapacity(box.value.count)
                prints.reserveCapacity(box.value.count)
                for i in box.value.keys.sorted() {
                    autoreleasepool {
                        guard let data = box.value[i],
                              let obs = unarchiveFeaturePrint(data) else { return }
                        ids.append(i)
                        prints.append(obs)
                    }
                }
                // ~140MB of archived blobs at 46k photos, dead the moment they are
                // unarchived. Nothing else references them, so drop them before the
                // longest phase of the scan rather than after.
                box.value = [:]

                let table = PrintTable(ids: ids, prints: prints)
                let n = table.count
                let totalPairs = max(1, n * (n - 1) / 2)
                let state = CompareState()
                let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
                // Scale the reporting batch to the job so small libraries still get a
                // moving bar instead of one jump from 0 to 100%.
                let reportEvery = max(1, totalPairs / 200)

                // Rows are triangular — row 0 compares against n-1 others, the last
                // against one — so contiguous blocks would leave whichever worker
                // holds the high rows idle almost immediately. Striding by worker
                // count keeps every core busy to the end.
                //
                // Rows are disjoint, so no two workers ever look at the same pair and
                // the match set is identical to the serial version; only its order
                // differs, which UnionFind does not care about.
                DispatchQueue.concurrentPerform(iterations: workers) { w in
                    var local: [(Int, Int)] = []
                    var pending = 0
                    var ii = w
                    while ii < n {
                        // computeDistance is Objective-C and autoreleases; over ~n²/2
                        // calls with no pool to drain, that alone grew the footprint
                        // by 904MB in 90 seconds. Drain once per row.
                        autoreleasepool {
                            let pi = table.prints[ii]
                            for jj in (ii + 1)..<n {
                                var dist: Float = 0
                                do {
                                    try pi.computeDistance(&dist, to: table.prints[jj])
                                    if dist < threshold {
                                        local.append((table.ids[ii], table.ids[jj]))
                                    }
                                } catch { }
                            }
                        }
                        pending += n - 1 - ii
                        if pending >= reportEvery {
                            if let frac = state.advance(by: pending, of: totalPairs) {
                                cmpCont.yield(frac)
                            }
                            pending = 0
                        }
                        ii += workers
                    }
                    if let frac = state.advance(by: pending, of: totalPairs) {
                        cmpCont.yield(frac)
                    }
                    state.merge(local)
                }

                cmpCont.finish()
                return state.matches
            }
            for await frac in cmpStream {
                progress = frac
                statusText = "Comparing fingerprints… \(Int(frac * 100))%"
                etaText = remainingTimeText(start: compareStart, fraction: frac)
            }
            let pairs = await compareTask.value
            progress = nil
            etaText = nil

            for (i, j) in pairs { uf.union(i, j) }
        }

        // Step 3: build groups.
        var clusters: [Int: [Int]] = [:]
        for i in 0..<allAssets.count {
            clusters[uf.find(i), default: []].append(i)
        }

        let resultGroups: [DuplicateGroup] = clusters.values.compactMap { idxs in
            guard idxs.count > 1 else { return nil }
            let assets = idxs.map { allAssets[$0] }
            let theseHashes = Set(idxs.compactMap { hashByIndex[$0] })
            let allHashed = idxs.allSatisfy { hashByIndex[$0] != nil }
            let mode: MatchMode = (allHashed && theseHashes.count == 1) ? .identical : .similar
            return DuplicateGroup(
                id: UUID().uuidString,
                assets: assets.sorted { ($0.creationDate, $0.id) < ($1.creationDate, $1.id) },
                mode: mode
            )
        }.sorted { a, b in
            if a.mode != b.mode { return a.mode == .identical }
            return a.assets.count > b.assets.count
        }

        groups = resultGroups
        let dupCount = resultGroups.reduce(0) { $0 + $1.assets.count - 1 }
        let identicalCount = resultGroups.filter { $0.mode == .identical }.count
        let similarCount = resultGroups.filter { $0.mode == .similar }.count
        if resultGroups.isEmpty {
            statusText = "No duplicates found across \(allAssets.count) photos."
        } else {
            var parts: [String] = []
            if identicalCount > 0 { parts.append("\(identicalCount) identical") }
            if similarCount > 0 { parts.append("\(similarCount) similar") }
            statusText = "\(parts.joined(separator: " · ")) groups · \(dupCount) extras of \(allAssets.count) photos."
        }

        await refreshCacheStats()
        progress = nil
        stepText = ""
        etaText = nil
        hintText = nil
        isScanning = false
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func selectAllButFirstInEveryGroup() {
        var next: Set<String> = []
        for g in groups {
            for a in g.assets.dropFirst() { next.insert(a.id) }
        }
        selected = next
    }

    func clearSelection() { selected = [] }

    func deleteSelected() async {
        let ids = Array(selected)
        guard !ids.isEmpty else { return }
        do {
            try await PhotoLibrary.deleteAssets(ids: ids)
            let trashed = Set(ids)
            groups = groups.compactMap { g in
                let remaining = g.assets.filter { !trashed.contains($0.id) }
                return remaining.count > 1
                    ? DuplicateGroup(id: g.id, assets: remaining, mode: g.mode)
                    : nil
            }
            selected = []
            statusText = "Deleted \(trashed.count) — recoverable from Recently Deleted."
        } catch {
            // The user cancelled the system confirmation, or deletion failed.
            statusText = "Nothing deleted."
        }
    }
}

// Runs an async transform over `items` with bounded concurrency, delivering each
// result back on the main actor via `onResult` (so it can touch @Published state).
@MainActor
func withTaskGroupLimited<Item: Sendable, Out: Sendable>(
    items: [Item],
    maxConcurrent: Int,
    transform: @escaping @Sendable (Item) async -> Out,
    onResult: @MainActor (Out) async -> Void
) async {
    var nextIndex = 0
    await withTaskGroup(of: Out.self) { group in
        func scheduleNext() {
            guard nextIndex < items.count else { return }
            let item = items[nextIndex]
            nextIndex += 1
            group.addTask { await transform(item) }
        }
        for _ in 0..<min(maxConcurrent, items.count) { scheduleNext() }
        while let result = await group.next() {
            await onResult(result)
            scheduleNext()
        }
    }
}

// Linear extrapolation from elapsed time and fraction done. Stays nil until 5% in
// so the first (wildly noisy) samples never surface as a bogus estimate.
// ponytail: no smoothing; add a moving average if the number visibly jitters.
nonisolated func remainingTimeText(start: Date, fraction: Double) -> String? {
    guard fraction >= 0.05, fraction < 1 else { return nil }
    let remaining = Date().timeIntervalSince(start) / fraction * (1 - fraction)
    guard remaining >= 3 else { return nil }
    let f = DateComponentsFormatter()
    f.allowedUnits = remaining < 3600 ? [.minute, .second] : [.hour, .minute]
    f.unitsStyle = .abbreviated
    f.zeroFormattingBehavior = .dropAll
    return f.string(from: remaining).map { "about \($0) left" }
}

nonisolated func formatBytes(_ bytes: Int64) -> String {
    let bcf = ByteCountFormatter()
    bcf.allowedUnits = [.useKB, .useMB, .useGB]
    bcf.countStyle = .file
    return bcf.string(fromByteCount: bytes)
}
