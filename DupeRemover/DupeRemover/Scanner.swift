import Foundation
import Combine
import Vision
import Photos
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Default distance below which two photos are considered "similar" (Vision feature
// print). 0.0 = identical embeddings; ~0.2 = visually near-duplicate; 0.5+ =
// different scenes. Exposed as a slider so users can tune strictness.
nonisolated let defaultTolerancePercent: Double = 20.0   // shown as 80% similarity

// Longest edge, in pixels, of the image handed to Vision. Vision downsizes
// internally anyway; 448px keeps feature prints stable while cutting decode cost.
nonisolated let visionInputPixel: CGFloat = 448

nonisolated func computeFeaturePrint(from cgImage: CGImage) -> VNFeaturePrintObservation? {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])
    return request.results?.first
}

/// A queue of our own for Vision work, deliberately outside Swift's cooperative
/// thread pool.
///
/// `perform` blocks its caller while Vision waits on an internal dispatch group.
/// Called straight from an `async` task, that parks a cooperative thread — and
/// the pool has only one thread per core and never grows to compensate. With
/// four analyses in flight on a four-core Mac, every cooperative thread ends up
/// parked inside Vision, the work Vision is waiting for can never be scheduled,
/// and the analyze phase stops dead with no error and no crash. The test suite
/// reproduced exactly that. Hopping to this queue keeps the blocking wait off
/// the pool, so the cores stay available.
nonisolated private let visionQueue = DispatchQueue(
    label: "com.matranc.duperemover.vision",
    qos: .userInitiated,
    attributes: .concurrent
)

nonisolated func computeFeaturePrintOffPool(from cgImage: CGImage) async -> VNFeaturePrintObservation? {
    await withCheckedContinuation { continuation in
        visionQueue.async {
            continuation.resume(returning: computeFeaturePrint(from: cgImage))
        }
    }
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

nonisolated enum ScanSource: Hashable {
    case folder
    case photosLibrary
}

// The two places the pipeline has to know where an item came from. Everything
// else — caching, grouping, comparison — works on the ScanItem alone.

nonisolated func sha256(of item: ScanItem) async -> String? {
    switch item.source {
    case .file(let url): return FileSource.sha256(of: url)
    case .asset(let id): return await PhotoLibrary.sha256(forAssetID: id)
    }
}

/// The downscaled image handed to Vision, same target size from either source.
nonisolated func visionImage(for item: ScanItem) async -> CGImage? {
    switch item.source {
    case .file(let url): return FileSource.cgImage(at: url, maxPixel: visionInputPixel)
    case .asset(let id): return await PhotoLibrary.cgImage(forAssetID: id, maxPixel: visionInputPixel)
    }
}

nonisolated let deviceWord: String = {
    #if os(macOS)
    "Mac"
    #else
    "device"
    #endif
}()

nonisolated let settingsAppName: String = {
    #if os(macOS)
    "System Settings"
    #else
    "Settings"
    #endif
}()

private let idleScanPrompt: String = {
    #if os(macOS)
    "Choose a folder to scan."
    #else
    "Tap Scan to find duplicates in your library."
    #endif
}()

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    // 0...1 drives a determinate progress bar; nil means indeterminate (spinner).
    @Published var progress: Double? = nil
    @Published var statusText = idleScanPrompt
    // "Step 2 of 4 · Hashing" — which phase of the scan is running.
    @Published var stepText = ""
    // "about 2m 30s left", nil until enough work is done to extrapolate.
    @Published var etaText: String?
    // Extra reassurance shown only on the slow phases.
    @Published var hintText: String?
    @Published var selected: Set<String> = []
    @Published var matchSimilar = false
    @Published var tolerancePercent: Double = defaultTolerancePercent
    @Published var cacheEntries = 0
    @Published var cacheSize: Int64 = 0
    /// Photos the last scan could not read, almost always iCloud originals that
    /// aren't on this device. Drives the explanation under an empty result.
    @Published private(set) var skippedCount = 0

    // Where to scan. Each platform defaults to the source it shipped with.
    #if os(macOS)
    @Published var scanSource: ScanSource = .folder
    #else
    @Published var scanSource: ScanSource = .photosLibrary
    #endif
    @Published private(set) var hasScanned = false
    @Published private(set) var lastScannedFolders: [URL] = []

    // nil = entire library. Otherwise scoped to one album.
    @Published var selectedAlbumID: String? = nil
    @Published var selectedAlbumTitle: String? = nil
    @Published var albums: [AlbumOption] = []

    @Published var authStatus = PhotoLibrary.authorizationStatus

    let cache: CacheStore

    /// Folders whose security-scoped access we currently hold. Claimed when the
    /// user picks them and held until the next pick, because thumbnails and
    /// deletion touch the files long after the scan ends.
    // ponytail: no bookmarks, so a relaunch re-prompts — same as the Mac app
    // has always behaved. Persist bookmarks if that ever grates.
    private var scopedFolders: [URL] = []

    /// `cacheDirectory` exists so tests can drive a real scan against a throwaway
    /// cache instead of the one the user's app is using.
    init(cacheDirectory: URL? = nil) {
        cache = CacheStore(directory: cacheDirectory)
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

    // MARK: Starting a scan

    /// Claims security-scoped access to picked folders and drops the previous
    /// claim. `startAccessing…` returns false for URLs that don't need a claim
    /// (an NSOpenPanel URL on macOS), which are simply not tracked for release.
    private func claimAccess(to folders: [URL]) {
        for url in scopedFolders { url.stopAccessingSecurityScopedResource() }
        scopedFolders = folders.filter { $0.startAccessingSecurityScopedResource() }
    }

    #if os(macOS)
    /// macOS keeps its NSOpenPanel; iOS presents `.fileImporter` from the view.
    /// One `.fileImporter` would serve both — tracked as an issue rather than
    /// changed under a merge.
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
    #endif

    func scanFolders(_ folders: [URL]) async {
        guard !folders.isEmpty else { return }
        scanSource = .folder
        claimAccess(to: folders)
        lastScannedFolders = folders

        await withScanChrome {
            self.stepText = "Step 1 of \(self.totalSteps) · Reading folders"
            self.statusText = "Looking for images…"
            return await Task.detached(priority: .userInitiated) {
                FileSource.enumerate(folders)
            }.value
        } emptyMessage: {
            "No image files found."
        }
    }

    func scanLibrary() async {
        guard hasFullOrLimitedAccess else { return }
        scanSource = .photosLibrary
        let albumID = selectedAlbumID

        await withScanChrome {
            self.stepText = "Step 1 of \(self.totalSteps) · Reading library"
            self.statusText = "Reading your library…"
            self.progress = 0

            // Read assets off the main actor, streaming progress back so the UI shows
            // a real progress bar (reading per-asset resources is slow on big
            // libraries).
            let readStart = Date()
            let (progressStream, progressCont) = AsyncStream<Double>.makeStream()
            let fetchTask = Task.detached(priority: .userInitiated) { () -> [ScanItem] in
                let assets = PhotoLibrary.fetchImageAssets(inAlbum: albumID) { frac in
                    progressCont.yield(frac)
                }
                progressCont.finish()
                return assets
            }
            for await frac in progressStream {
                self.progress = frac
                self.statusText = "Reading your library… \(Int(frac * 100))%"
                self.etaText = remainingTimeText(start: readStart, fraction: frac)
            }
            return await fetchTask.value
        } emptyMessage: {
            // An empty library almost never means an empty library. Far more often
            // the app holds access to selected photos only: the fetch then returns
            // nothing at all, and a bare "No photos found" reads like a broken app.
            if self.authStatus == .limited {
                return "Dupe Remover can only see the photos you picked for it, and "
                    + "none of them are here. Give it access to more photos in "
                    + "\(settingsAppName) ▸ Privacy & Security ▸ Photos."
            }
            return "No photos found\(self.selectedAlbumTitle.map { " in \($0)" } ?? "")."
        }
    }

    func rescan() async {
        guard hasScanned, !isScanning else { return }
        switch scanSource {
        case .folder: await scanFolders(lastScannedFolders)
        case .photosLibrary: await scanLibrary()
        }
    }

    private var totalSteps: Int { matchSimilar ? 4 : 2 }

    /// Resets the UI, runs `read` to gather items, then hands them to `runScan`.
    /// The two sources differ only in that first step.
    private func withScanChrome(
        read: () async -> [ScanItem],
        emptyMessage: () -> String
    ) async {
        isScanning = true
        groups = []
        selected = []
        progress = 0
        etaText = nil
        hintText = nil
        skippedCount = 0
        hasScanned = true

        #if os(iOS)
        // Scanning is long and touch-free, so the display would otherwise sleep and
        // suspend the app mid-scan. macOS keeps running with the display asleep.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif

        let items = await read()
        progress = nil
        etaText = nil

        guard !items.isEmpty else {
            statusText = emptyMessage()
            stepText = ""
            isScanning = false
            return
        }
        await runScan(items)
    }

    private func runScan(_ allAssets: [ScanItem]) async {
        let totalSteps = self.totalSteps
        func beginStep(_ n: Int, _ name: String) {
            stepText = "Step \(n) of \(totalSteps) · \(name)"
            etaText = nil
            hintText = nil
        }

        let uf = UnionFind(count: allAssets.count)
        var hashByIndex: [Int: String] = [:]
        // Photos whose pixels we could not get at. Overwhelmingly this means the
        // original lives in iCloud and isn't on this device: both the hash and the
        // fingerprint deliberately refuse to download it. Silently skipping them
        // makes a scan look like it did nothing, so they get counted and reported.
        var unreadable: Set<String> = []

        // Step 1: identical detection by SHA-256, only for pixel-dimension
        // collisions (byte-identical files always share their dimensions, so this
        // skips hashing the vast majority of one-of-a-kind photos).
        var byDims: [Int64: [Int]] = [:]
        for (i, a) in allAssets.enumerated() { byDims[a.token, default: []].append(i) }
        let candidateIndexes = byDims.values.filter { $0.count > 1 }.flatMap { $0 }

        beginStep(2, "Finding identical photos")
        statusText = "Hashing \(candidateIndexes.count) of \(allAssets.count) photos…"

        var toHash: [Int] = []
        for i in candidateIndexes {
            let a = allAssets[i]
            if let entry = await cache.get(id: a.id, mtime: a.mtime, token: a.token),
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
                let h = await sha256(of: allAssets[i])
                return (i, h)
            } onResult: { result in
                let (i, h) = result
                done += 1
                if let h {
                    hashByIndex[i] = h
                    let a = allAssets[i]
                    await self.cache.setHash(id: a.id, mtime: a.mtime, token: a.token, sha256: h)
                } else {
                    unreadable.insert(allAssets[i].id)
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
                if let entry = await cache.get(id: a.id, mtime: a.mtime, token: a.token),
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
                    guard let cg = await visionImage(for: allAssets[i]),
                          let obs = await computeFeaturePrintOffPool(from: cg),
                          let data = archiveFeaturePrint(obs) else { return (i, nil) }
                    return (i, ArchivedPrint(data: data, revision: obs.requestRevision))
                } onResult: { result in
                    let (i, archived) = result
                    done += 1
                    if let archived {
                        printsData[i] = archived.data
                        unreadable.remove(allAssets[i].id)
                        let a = allAssets[i]
                        await self.cache.setFeaturePrint(
                            id: a.id, mtime: a.mtime, token: a.token,
                            data: archived.data, revision: archived.revision)
                    } else {
                        unreadable.insert(allAssets[i].id)
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
            let threshold = Float(tolerancePercent / 100.0)
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
                items: assets.sorted { ($0.creationDate, $0.id) < ($1.creationDate, $1.id) },
                mode: mode
            )
        }.sorted { a, b in
            if a.mode != b.mode { return a.mode == .identical }
            return a.items.count > b.items.count
        }

        groups = resultGroups
        let dupCount = resultGroups.reduce(0) { $0 + $1.items.count - 1 }
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
        skippedCount = unreadable.count
        if !unreadable.isEmpty {
            // Worth saying out loud: on a Mac set to optimise storage this can be
            // the entire library, and the scan then looks broken rather than
            // limited. Comparing photos means reading their pixels, and the app
            // will not pull an original down from iCloud to do it.
            statusText += scanSource == .photosLibrary
                ? " \(unreadable.count) couldn't be read — they're not downloaded to this \(deviceWord)."
                : " \(unreadable.count) file\(unreadable.count == 1 ? "" : "s") couldn't be read."
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
            for a in g.items.dropFirst() { next.insert(a.id) }
        }
        selected = next
    }

    func clearSelection() { selected = [] }

    /// Everything selected goes somewhere recoverable: files to the Trash, assets
    /// to Recently Deleted. Files are trashed one by one so one unwritable file
    /// doesn't cost the user the whole batch.
    func deleteSelected() async {
        let chosen = groups.flatMap { $0.items }.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }

        var trashed: Set<String> = []
        var failed = 0

        for item in chosen {
            guard let url = item.localURL else { continue }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                trashed.insert(item.id)
            } catch {
                failed += 1
            }
        }

        let assetIDs = chosen.compactMap { item -> String? in
            if case .asset(let id) = item.source { return id }
            return nil
        }
        if !assetIDs.isEmpty {
            do {
                // The system shows its own confirmation here and throws if the user
                // declines it.
                try await PhotoLibrary.deleteAssets(ids: assetIDs)
                trashed.formUnion(assetIDs)
            } catch {
                failed += assetIDs.count
            }
        }

        groups = groups.compactMap { g in
            let remaining = g.items.filter { !trashed.contains($0.id) }
            return remaining.count > 1
                ? DuplicateGroup(id: g.id, items: remaining, mode: g.mode)
                : nil
        }
        selected = []
        if !trashed.isEmpty {
            statusText = "Deleted \(trashed.count) — recoverable from the Trash or Recently Deleted."
                + (failed > 0 ? " \(failed) could not be deleted." : "")
        } else if failed > 0 {
            // Not every location supports a Trash — a file the picker handed us
            // from a read-only or provider-backed folder can refuse the move. Say
            // so, rather than leaving the user staring at "nothing happened".
            statusText = "Couldn't delete \(failed) item\(failed == 1 ? "" : "s"). "
                + "They may be somewhere the system won't let the app move files from."
        } else {
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
