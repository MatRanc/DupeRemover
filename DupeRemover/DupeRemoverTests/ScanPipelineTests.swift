import Foundation
import Testing
@testable import DupeRemover

/// End-to-end runs of the real scan, driven through `ScanViewModel` exactly as
/// the UI drives it: pick folders, scan, inspect groups, select, delete. This is
/// the same pipeline on both platforms, so a green run here on either
/// destination is evidence for both.
@MainActor
@Suite("Scan pipeline")
struct ScanPipelineTests {

    private func model(_ label: String = "vm") -> ScanViewModel {
        ScanViewModel(cacheDirectory: TestImages.tempDir("cache-\(label)"))
    }

    // MARK: Identical detection

    @Test("byte-identical copies land in one identical group")
    func identicalCopiesGroup() async {
        let dir = TestImages.tempDir("identical")
        let original = TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.copy(original, to: "beach copy.png")
        TestImages.write(.forest, to: dir, named: "forest.png")

        let vm = model()
        await vm.scanFolders([dir])

        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.mode == .identical)
        #expect(vm.groups.first?.items.count == 2)
        #expect(Set(vm.groups.first!.items.map(\.name)) == ["beach.png", "beach copy.png"])
        #expect(!vm.isScanning)
        #expect(vm.progress == nil)
        #expect(vm.stepText.isEmpty)
    }

    @Test("three copies of one photo make one group of three")
    func threeCopiesOneGroup() async {
        let dir = TestImages.tempDir("triple")
        let original = TestImages.write(.cityscape, to: dir, named: "city.png")
        TestImages.copy(original, to: "city-2.png")
        TestImages.copy(original, to: "city-3.png")

        let vm = model()
        await vm.scanFolders([dir])

        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.items.count == 3)
    }

    @Test("distinct photos produce no groups")
    func noFalsePositives() async {
        let dir = TestImages.tempDir("distinct")
        TestImages.write(.beach, to: dir, named: "a.png")
        TestImages.write(.forest, to: dir, named: "b.png")
        TestImages.write(.cityscape, to: dir, named: "c.png")
        TestImages.write(.portrait, to: dir, named: "d.png")

        let vm = model()
        await vm.scanFolders([dir])

        #expect(vm.groups.isEmpty)
        #expect(vm.statusText.contains("No duplicates found"))
    }

    /// Identical detection must not depend on the similarity pass, and must not
    /// need it: same bytes is same bytes.
    @Test("copies group whether or not similar matching is on", arguments: [false, true])
    func identicalIndependentOfSimilar(matchSimilar: Bool) async {
        let dir = TestImages.tempDir("indep")
        let original = TestImages.write(.portrait, to: dir, named: "p.png")
        TestImages.copy(original, to: "p2.png")

        let vm = model()
        vm.matchSimilar = matchSimilar
        await vm.scanFolders([dir])

        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.mode == .identical)
    }

    // MARK: Similar detection
    //
    // Distances were measured on these exact images: the same subject in two
    // formats sits at ~0.17-0.32, any two different subjects at ~0.76 or more.
    // The thresholds below leave at least a 2x margin on both sides so a small
    // Vision revision drift can't flip the result.

    @Test("a re-encoded copy of the same photo groups as similar", .enabled(if: TestSupport.visionAvailable))
    func similarGroupsWhenEnabled() async {
        let dir = TestImages.tempDir("similar")
        TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.write(.beach, to: dir, named: "beach.heic")
        TestImages.write(.forest, to: dir, named: "forest.png")

        let vm = model()
        vm.matchSimilar = true
        vm.similarityPercent = 40

        await vm.scanFolders([dir])

        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.mode == .similar)
        #expect(Set(vm.groups.first!.items.map(\.name)) == ["beach.png", "beach.heic"])
    }

    @Test("similar photos are left alone when the toggle is off")
    func similarIgnoredWhenDisabled() async {
        let dir = TestImages.tempDir("similar-off")
        TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.write(.beach, to: dir, named: "beach.heic")

        let vm = model()
        vm.matchSimilar = false
        vm.similarityPercent = 40

        await vm.scanFolders([dir])
        #expect(vm.groups.isEmpty)
    }

    @Test("the strictness slider actually tightens matching", .enabled(if: TestSupport.visionAvailable))
    func strictnessTightens() async {
        let dir = TestImages.tempDir("strict")
        TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.write(.beach, to: dir, named: "beach.heic")

        let loose = model("loose")
        loose.matchSimilar = true
        loose.similarityPercent = 40
        await loose.scanFolders([dir])
        #expect(loose.groups.count == 1)

        let strict = model("strict")
        strict.matchSimilar = true
        strict.similarityPercent = 5
        await strict.scanFolders([dir])
        #expect(strict.groups.isEmpty)
    }

    @Test("identical groups sort ahead of similar ones", .enabled(if: TestSupport.visionAvailable))
    func identicalSortsFirst() async {
        let dir = TestImages.tempDir("order")
        let city = TestImages.write(.cityscape, to: dir, named: "city.png")
        TestImages.copy(city, to: "city-copy.png")
        TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.write(.beach, to: dir, named: "beach.heic")

        let vm = model()
        vm.matchSimilar = true
        vm.similarityPercent = 40
        await vm.scanFolders([dir])

        #expect(vm.groups.count == 2)
        #expect(vm.groups.first?.mode == .identical)
        #expect(vm.groups.last?.mode == .similar)
    }

    // MARK: Cache behaviour

    /// The promise the cache makes: a second scan of an unchanged folder returns
    /// the same answer without recomputing anything.
    @Test("a warm cache gives the same result and writes nothing new")
    func warmCacheMatchesColdScan() async {
        let dir = TestImages.tempDir("warm")
        let cacheDir = TestImages.tempDir("warm-cache")
        let beach = TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.copy(beach, to: "beach-copy.png")
        TestImages.write(.beach, to: dir, named: "beach.heic")
        TestImages.write(.forest, to: dir, named: "forest.png")

        let cold = ScanViewModel(cacheDirectory: cacheDir)
        cold.matchSimilar = true
        cold.similarityPercent = 40
        await cold.scanFolders([dir])
        let coldGroups = cold.groups.map { Set($0.items.map(\.id)) }
        #expect(await cold.cache.entryCount() > 0)

        // A fresh model, so the store reloads (and compacts) from disk first.
        let warm = ScanViewModel(cacheDirectory: cacheDir)
        warm.matchSimilar = true
        warm.similarityPercent = 40
        let sizeBeforeScan = await warm.cache.diskSize()
        await warm.scanFolders([dir])

        #expect(warm.groups.map { Set($0.items.map(\.id)) } == coldGroups)
        #expect(await warm.cache.diskSize() == sizeBeforeScan)   // nothing recomputed
    }

    @Test("editing a file invalidates its cached work")
    func editedFileIsRecomputed() async {
        let dir = TestImages.tempDir("edited")
        let cacheDir = TestImages.tempDir("edited-cache")
        let beach = TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.copy(beach, to: "beach-copy.png")

        let first = ScanViewModel(cacheDirectory: cacheDir)
        await first.scanFolders([dir])
        #expect(first.groups.count == 1)

        // Replace one of the two with a different picture, at a different size so
        // the byte count moves too.
        TestImages.write(.forest, to: dir, named: "beach-copy.png", size: 640)

        let second = ScanViewModel(cacheDirectory: cacheDir)
        await second.scanFolders([dir])
        #expect(second.groups.isEmpty)
    }

    @Test("clearing the cache empties it without breaking the next scan")
    func clearCacheThenRescan() async {
        let dir = TestImages.tempDir("cleared")
        let cacheDir = TestImages.tempDir("cleared-cache")
        let beach = TestImages.write(.beach, to: dir, named: "beach.png")
        TestImages.copy(beach, to: "beach-copy.png")

        let vm = ScanViewModel(cacheDirectory: cacheDir)
        await vm.scanFolders([dir])
        #expect(vm.groups.count == 1)

        await vm.clearCache()
        #expect(vm.cacheEntries == 0)

        await vm.scanFolders([dir])
        #expect(vm.groups.count == 1)
        #expect(await vm.cache.entryCount() > 0)
    }

    // MARK: Selection and deletion

    @Test("select all but first leaves exactly one keeper per group")
    func selectAllButFirst() async {
        let dir = TestImages.tempDir("select")
        let city = TestImages.write(.cityscape, to: dir, named: "city.png")
        TestImages.copy(city, to: "city-2.png")
        TestImages.copy(city, to: "city-3.png")

        let vm = model()
        await vm.scanFolders([dir])
        vm.selectAllButFirstInEveryGroup()

        #expect(vm.selected.count == 2)
        for group in vm.groups {
            let kept = group.items.filter { !vm.selected.contains($0.id) }
            #expect(kept.count == 1)
        }

        vm.clearSelection()
        #expect(vm.selected.isEmpty)
    }

    @Test("deleting removes the file and rebuilds the groups")
    func deleteSelected() async throws {
        let dir = TestImages.tempDir("delete")
        // Distinctive names so anything that reaches the Trash is identifiable.
        let stamp = UUID().uuidString.prefix(8)
        let original = TestImages.write(.portrait, to: dir, named: "dupetest-\(stamp)-keep.png")
        let copy = TestImages.copy(original, to: "dupetest-\(stamp)-extra.png")

        let vm = model()
        await vm.scanFolders([dir])
        #expect(vm.groups.count == 1)

        vm.selected = [copy.path]
        await vm.deleteSelected()

        #expect(vm.selected.isEmpty)
        // The keeper is never touched, whatever happens to the other one.
        #expect(FileManager.default.fileExists(atPath: original.path))

        // Not every location has a Trash to move a file to: iOS refuses it for
        // paths inside the app's own container, for instance. Either outcome is
        // acceptable, but they have to stay consistent — a file reported as
        // deleted must really be gone, and one that isn't must still be listed.
        if vm.statusText.contains("Deleted 1") {
            #expect(!FileManager.default.fileExists(atPath: copy.path))
            #expect(vm.groups.isEmpty)      // one of a pair gone is no longer a group
        } else {
            #expect(vm.statusText.contains("Couldn't delete"))
            #expect(FileManager.default.fileExists(atPath: copy.path))
            #expect(vm.groups.first?.items.count == 2)
        }

        // On a Mac there is always a Trash, so nothing excuses a failure there.
        #if os(macOS)
        #expect(vm.statusText.contains("Deleted 1"))
        #endif

        // Don't leave test files sitting in the user's Trash.
        let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        if let trash, let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
            for name in names where name.hasPrefix("dupetest-\(stamp)") {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
            }
        }
    }

    @Test("deleting nothing does nothing")
    func deleteWithEmptySelection() async {
        let dir = TestImages.tempDir("delete-none")
        let original = TestImages.write(.beach, to: dir, named: "a.png")
        TestImages.copy(original, to: "b.png")

        let vm = model()
        await vm.scanFolders([dir])
        let before = vm.groups.count
        await vm.deleteSelected()

        #expect(vm.groups.count == before)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    // MARK: Edge cases

    @Test("an empty folder says so and leaves the UI idle")
    func emptyFolder() async {
        let vm = model()
        await vm.scanFolders([TestImages.tempDir("nothing")])

        #expect(vm.groups.isEmpty)
        #expect(vm.statusText == "No image files found.")
        #expect(!vm.isScanning)
        #expect(vm.stepText.isEmpty)
    }

    @Test("scanning no folders at all is a no-op")
    func noFoldersPicked() async {
        let vm = model()
        await vm.scanFolders([])
        #expect(!vm.isScanning)
        #expect(!vm.hasScanned)
    }

    @Test("a corrupt image doesn't sink the scan")
    func corruptImageSurvives() async throws {
        let dir = TestImages.tempDir("corrupt-scan")
        let original = TestImages.write(.beach, to: dir, named: "good.png")
        TestImages.copy(original, to: "good-copy.png")
        try Data(repeating: 0x00, count: 2048).write(to: dir.appendingPathComponent("broken.png"))

        let vm = model()
        vm.matchSimilar = true
        vm.similarityPercent = 40
        await vm.scanFolders([dir])

        // The good pair is still found; the unreadable file simply has no print.
        #expect(vm.groups.count == 1)
        #expect(vm.groups.first?.items.count == 2)
        #expect(!vm.isScanning)
    }

    @Test("photos of the same size that differ are not called identical")
    func sameSizeDifferentBytes() async {
        let dir = TestImages.tempDir("same-size")
        // Two different subjects rendered at the same dimensions: their byte
        // counts can collide, which is exactly when the SHA-256 pass has to
        // disagree with the cheap token.
        TestImages.write(.beach, to: dir, named: "a.png", size: 256)
        TestImages.write(.cityscape, to: dir, named: "b.png", size: 256)

        let vm = model()
        await vm.scanFolders([dir])
        #expect(vm.groups.isEmpty)
    }

    @Test("rescan repeats the last folder scan")
    func rescanRepeats() async {
        let dir = TestImages.tempDir("rescan")
        let original = TestImages.write(.forest, to: dir, named: "a.png")
        TestImages.copy(original, to: "b.png")

        let vm = model()
        await vm.scanFolders([dir])
        #expect(vm.groups.count == 1)
        #expect(vm.lastScannedFolders == [dir])

        vm.groups = []
        await vm.rescan()
        #expect(vm.groups.count == 1)
    }

    /// Regression guard for a real stall: Vision's `perform` blocks its caller,
    /// so calling it straight from an async task parks a cooperative thread.
    /// Enough analyses at once parked every thread in the pool and the scan
    /// stopped dead — no crash, no error, just silence. Four scans in parallel
    /// forces far more concurrency than one user-driven scan ever does; if the
    /// blocking call ever moves back onto the pool, this hangs and the time
    /// limit fails it.
    @Test("scans running at the same time can't starve the thread pool",
          .timeLimit(.minutes(2)), .enabled(if: TestSupport.visionAvailable))
    func concurrentScansDoNotStall() async {
        // Subjects are kept apart on purpose: a third beach photo would join the
        // identical beach pair through the similar pass and leave one group, not
        // two.
        let dirs = (0..<4).map { i -> URL in
            let dir = TestImages.tempDir("parallel-\(i)")
            let city = TestImages.write(.cityscape, to: dir, named: "city.png")
            TestImages.copy(city, to: "city-copy.png")
            TestImages.write(.beach, to: dir, named: "beach.png")
            TestImages.write(.beach, to: dir, named: "beach.heic")
            TestImages.write(.forest, to: dir, named: "forest.png")
            return dir
        }

        let models = (0..<4).map { i -> ScanViewModel in
            let vm = model("parallel-\(i)")
            vm.matchSimilar = true
            vm.similarityPercent = 40
            return vm
        }

        await withTaskGroup(of: Void.self) { group in
            for (vm, dir) in zip(models, dirs) {
                group.addTask { @MainActor in await vm.scanFolders([dir]) }
            }
        }

        for vm in models {
            #expect(!vm.isScanning)
            #expect(vm.groups.count == 2)      // one identical pair, one similar pair
        }
    }

    // MARK: Photos source

    /// The Photos library itself needs a real device library and a granted
    /// permission, so what's checked here is the guard: without access, asking
    /// for a library scan must do nothing rather than half-run or crash.
    @Test("a library scan without permission is refused quietly")
    func libraryScanNeedsPermission() async {
        let vm = model()
        guard !vm.hasFullOrLimitedAccess else { return }   // a real library is present

        await vm.scanLibrary()
        #expect(!vm.isScanning)
        #expect(!vm.hasScanned)
        #expect(vm.groups.isEmpty)
    }
}
