import Foundation
import Vision
import Testing
@testable import DupeRemover

/// The matching primitives underneath the scan: feature prints, the distances
/// between them, and the clustering that turns pairs into groups.
@Suite("Matching")
struct MatchingTests {

    private func print448(_ url: URL) -> VNFeaturePrintObservation {
        let cg = FileSource.cgImage(at: url, maxPixel: visionInputPixel)!
        return computeFeaturePrint(from: cg)!
    }

    private func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = 0
        try! a.computeDistance(&d, to: b)
        return d
    }

    /// The property the whole similar-matching feature rests on. Asserted as an
    /// ordering rather than against fixed numbers, so it stays true if Apple
    /// re-tunes the model.
    @Test("the same photo re-encoded is far closer than a different photo", .enabled(if: TestSupport.visionAvailable))
    func distanceOrdering() {
        let dir = TestImages.tempDir("distance")
        let beachPNG = TestImages.write(.beach, to: dir, named: "beach.png")
        let beachHEIC = TestImages.write(.beach, to: dir, named: "beach.heic")
        let forest = TestImages.write(.forest, to: dir, named: "forest.png")

        let same = distance(print448(beachPNG), print448(beachHEIC))
        let different = distance(print448(beachPNG), print448(forest))

        #expect(same < different)
        #expect(same < 0.5)          // measured ~0.17 on these images
        #expect(different > 0.6)     // measured ~0.96
    }

    @Test("a print survives archiving and still measures the same distance", .enabled(if: TestSupport.visionAvailable))
    func archiveRoundTrip() {
        let dir = TestImages.tempDir("archive")
        let a = print448(TestImages.write(.cityscape, to: dir, named: "a.png"))
        let b = print448(TestImages.write(.portrait, to: dir, named: "b.png"))

        let data = archiveFeaturePrint(a)!
        let restored = unarchiveFeaturePrint(data)!

        #expect(restored.requestRevision == a.requestRevision)
        #expect(distance(restored, b) == distance(a, b))
    }

    @Test("garbage never unarchives into a usable print")
    func unarchiveGarbage() {
        #expect(unarchiveFeaturePrint(Data(repeating: 0x42, count: 128)) == nil)
        #expect(unarchiveFeaturePrint(Data()) == nil)
    }

    /// Entries written before revisions were tracked carry none, so the scan
    /// unarchives them to find out rather than recomputing a whole library.
    @Test("a legacy cache entry is used only if its print is really current", .enabled(if: TestSupport.visionAvailable))
    func comparablePrintChecksLegacyEntries() {
        let dir = TestImages.tempDir("legacy-print")
        let data = archiveFeaturePrint(print448(TestImages.write(.beach, to: dir, named: "a.png")))!
        let current = currentFeaturePrintRevision

        let tracked = CacheEntry(mtime: 1, token: 1, featurePrintData: data, featurePrintRevision: current)
        #expect(comparableFeaturePrint(tracked, revision: current) == data)
        #expect(comparableFeaturePrint(tracked, revision: current + 1) == nil)

        let legacy = CacheEntry(mtime: 1, token: 1, featurePrintData: data, featurePrintRevision: nil)
        #expect(comparableFeaturePrint(legacy, revision: current) == data)
        #expect(comparableFeaturePrint(legacy, revision: current + 1) == nil)

        let empty = CacheEntry(mtime: 1, token: 1)
        #expect(comparableFeaturePrint(empty, revision: current) == nil)
    }

    @Test("union-find chains pairs into one group")
    func unionFindClusters() {
        let uf = UnionFind(count: 6)
        uf.union(0, 1)
        uf.union(1, 2)      // 0-1-2 are one cluster by transitivity
        uf.union(4, 5)

        #expect(uf.find(0) == uf.find(2))
        #expect(uf.find(4) == uf.find(5))
        #expect(uf.find(0) != uf.find(3))
        #expect(uf.find(3) == uf.find(3))
        #expect(uf.find(0) != uf.find(4))
    }

    @Test("the ETA stays quiet until it has something honest to say")
    func remainingTime() {
        let start = Date().addingTimeInterval(-10)
        #expect(remainingTimeText(start: start, fraction: 0.0) == nil)    // too early
        #expect(remainingTimeText(start: start, fraction: 0.01) == nil)   // still noise
        #expect(remainingTimeText(start: start, fraction: 1.0) == nil)    // done
        #expect(remainingTimeText(start: start, fraction: 0.5) != nil)
        #expect(remainingTimeText(start: start, fraction: 0.5)?.contains("left") == true)
    }

    @Test("byte sizes are formatted for humans")
    func byteFormatting() {
        #expect(formatBytes(5_000_000).contains("MB"))
        #expect(formatBytes(2_000_000_000).contains("GB"))
        #expect(!formatBytes(0).isEmpty)      // ByteCountFormatter says "Zero KB"
    }
}
