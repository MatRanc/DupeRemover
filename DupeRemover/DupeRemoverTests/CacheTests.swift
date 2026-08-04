import Foundation
import Testing
@testable import DupeRemover

/// The cache is the one component that can silently cost a user hours: a bad
/// read recomputes a whole library, a bad write loses a finished scan. These
/// cover the round trip, recovery from a kill mid-write, compaction, and the
/// one-time upgrade from either pre-merge app's cache.plist.
@Suite("Cache")
struct CacheTests {

    private func entry(_ store: CacheStore, _ id: String) async -> CacheEntry? {
        await store.get(id: id, mtime: 1, token: 100)
    }

    @Test("what one store writes, the next one reads")
    func roundTrip() async {
        let dir = TestImages.tempDir("cache")
        let a = CacheStore(directory: dir)
        await a.setHash(id: "photo-1", mtime: 1, token: 100, sha256: "abc")
        await a.setFeaturePrint(id: "photo-2", mtime: 1, token: 100, data: Data([1, 2, 3]), revision: 2)
        await a.flushNow()

        let b = CacheStore(directory: dir)
        #expect(await entry(b, "photo-1")?.sha256 == "abc")
        #expect(await entry(b, "photo-2")?.featurePrintData == Data([1, 2, 3]))
        #expect(await b.entryCount() == 2)
    }

    /// A real archived print is ~3KB of arbitrary bytes, and binary plists use
    /// different length markers for small vs large data. Byte-exact round-tripping
    /// is what keeps distances — and so match quality — stable across launches.
    @Test("a realistic feature print survives byte-for-byte")
    func realisticBlobRoundTrip() async {
        let dir = TestImages.tempDir("cache")
        var blob = Data(count: 3072)
        for i in blob.indices { blob[i] = UInt8.random(in: 0...255) }

        let a = CacheStore(directory: dir)
        await a.setFeaturePrint(id: "p", mtime: 1, token: 100, data: blob, revision: 2)
        await a.flushNow()

        let out = await entry(CacheStore(directory: dir), "p")?.featurePrintData
        #expect(out == blob)
        #expect(out?.count == 3072)
    }

    /// Vision's print format is versioned and computeDistance throws across
    /// versions — which the scan swallows, so a stale print reads as "no
    /// duplicates found" rather than as an error. The revision has to gate reads.
    @Test("the print revision survives and gates reads")
    func revisionGating() async {
        let dir = TestImages.tempDir("cache")
        let a = CacheStore(directory: dir)
        await a.setFeaturePrint(id: "p", mtime: 1, token: 100, data: Data([7, 7, 7]), revision: 2)
        await a.flushNow()

        let e = await entry(CacheStore(directory: dir), "p")
        #expect(e?.featurePrintRevision == 2)
        #expect(e?.featurePrint(revision: 2) == Data([7, 7, 7]))
        #expect(e?.featurePrint(revision: 3) == nil)
        #expect(e?.featurePrint(revision: 1) == nil)
    }

    @Test("a revision bump keeps the hash, drops only the print")
    func revisionBumpKeepsHash() async {
        let dir = TestImages.tempDir("cache")
        let a = CacheStore(directory: dir)
        await a.setHash(id: "p", mtime: 1, token: 100, sha256: "abc")
        await a.setFeaturePrint(id: "p", mtime: 1, token: 100, data: Data([1]), revision: 2)
        await a.flushNow()

        let e = await entry(CacheStore(directory: dir), "p")
        #expect(e?.featurePrint(revision: 3) == nil)
        #expect(e?.sha256 == "abc")
    }

    @Test("an entry from before revisions were tracked never passes as current")
    func unknownRevisionNeverMatches() {
        let legacy = CacheEntry(mtime: 1, token: 100, sha256: nil,
                                featurePrintData: Data([1, 2]), featurePrintRevision: nil)
        #expect(legacy.featurePrint(revision: 2) == nil)
    }

    @Test("a later record merges with the earlier one instead of clobbering it")
    func recordsMerge() async {
        let dir = TestImages.tempDir("cache")
        let a = CacheStore(directory: dir)
        await a.setHash(id: "p", mtime: 1, token: 100, sha256: "abc")
        await a.setFeaturePrint(id: "p", mtime: 1, token: 100, data: Data([9]), revision: 2)
        await a.flushNow()

        let e = await entry(CacheStore(directory: dir), "p")
        #expect(e?.sha256 == "abc")
        #expect(e?.featurePrintData == Data([9]))
    }

    /// A kill mid-append truncates the last record. Everything written before it
    /// must survive — that is the whole point of an append-only log.
    @Test("a torn final record is dropped and the rest survive")
    func tornRecord() async {
        let dir = TestImages.tempDir("cache")
        let log = dir.appendingPathComponent("cache.log")
        let a = CacheStore(directory: dir)
        for i in 0..<20 {
            await a.setHash(id: "photo-\(i)", mtime: 1, token: 100, sha256: "h\(i)")
        }
        await a.flushNow()

        let intact = try! Data(contentsOf: log)
        try! intact.dropLast(9).write(to: log)      // sever the final record

        let b = CacheStore(directory: dir)
        #expect(await b.entryCount() == 19)
        #expect(await entry(b, "photo-0")?.sha256 == "h0")
    }

    @Test("a changed mtime or token misses, so an edited photo is recomputed")
    func stalenessMisses() async {
        let dir = TestImages.tempDir("cache")
        let a = CacheStore(directory: dir)
        await a.setHash(id: "p", mtime: 1, token: 100, sha256: "abc")
        #expect(await a.get(id: "p", mtime: 2, token: 100) == nil)
        #expect(await a.get(id: "p", mtime: 1, token: 999) == nil)
        #expect(await a.get(id: "p", mtime: 1, token: 100)?.sha256 == "abc")
    }

    @Test("superseded records are compacted at load, not during a scan")
    func compaction() async {
        let dir = TestImages.tempDir("cache")
        let log = dir.appendingPathComponent("cache.log")
        let a = CacheStore(directory: dir)
        for _ in 0..<50 {
            await a.setHash(id: "same", mtime: 1, token: 100, sha256: "abc")
        }
        await a.flushNow()
        let fat = try! Data(contentsOf: log).count

        _ = CacheStore(directory: dir)               // compacts on load
        let slim = try! Data(contentsOf: log).count
        #expect(slim < fat)
        #expect(await entry(CacheStore(directory: dir), "same")?.sha256 == "abc")
    }

    /// Both pre-merge apps wrote a whole-file plist and each named the change
    /// token differently — iOS `pixelCount`, macOS `size`. Written here as raw
    /// plist dictionaries because the types that produced them no longer exist.
    @Test("an existing cache from either old app is adopted", arguments: ["pixelCount", "size"])
    func legacyPlistAdopted(tokenKey: String) async {
        let dir = TestImages.tempDir("cache")
        let legacy = ["old-1": ["mtime": 1.0, tokenKey: 100, "sha256": "xyz"] as [String: Any]]
        let data = try! PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        try! data.write(to: dir.appendingPathComponent("cache.plist"))

        let a = CacheStore(directory: dir)
        #expect(await entry(a, "old-1")?.sha256 == "xyz")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cache.plist").path))

        let b = CacheStore(directory: dir)
        #expect(await entry(b, "old-1")?.sha256 == "xyz")
    }

    @Test("clear empties the store and leaves it writable")
    func clearStaysWritable() async {
        let dir = TestImages.tempDir("cache")
        let a = CacheStore(directory: dir)
        await a.setHash(id: "p", mtime: 1, token: 100, sha256: "abc")
        await a.clear()
        #expect(await a.entryCount() == 0)

        await a.setHash(id: "q", mtime: 1, token: 100, sha256: "def")
        await a.flushNow()

        let b = CacheStore(directory: dir)
        #expect(await entry(b, "q")?.sha256 == "def")
        #expect(await entry(b, "p") == nil)
    }
}
