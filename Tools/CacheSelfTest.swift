// Self-check for the append-only cache log. No test target needed:
//
//   swiftc -parse-as-library DupeRemover/DupeRemover/Cache.swift Tools/CacheSelfTest.swift \
//       -o /tmp/cachecheck && /tmp/cachecheck
//
// Covers the parts that can silently lose a user's scan: round-trip through the
// log, recovery from a record torn by a mid-write kill, compaction at load, and
// the one-time upgrade from the old cache.plist.

import Foundation

func check(_ condition: Bool, _ what: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
        exit(1)
    }
    print("ok — \(what)")
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cachecheck-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func entry(_ store: CacheStore, _ id: String) async -> CacheEntry? {
    await store.get(id: id, mtime: 1, pixelCount: 100)
}

@main
struct CacheSelfTest {
    static func main() async {

        // Round-trip: what one store writes, the next one reads.
        do {
            let dir = tempDir()
            let a = CacheStore(directory: dir)
            await a.setHash(id: "photo-1", mtime: 1, pixelCount: 100, sha256: "abc")
            await a.setFeaturePrint(id: "photo-2", mtime: 1, pixelCount: 100, data: Data([1, 2, 3]), revision: 2)
            await a.flushNow()

            let b = CacheStore(directory: dir)
            check(await entry(b, "photo-1")?.sha256 == "abc", "hash survives a reopen")
            check(await entry(b, "photo-2")?.featurePrintData == Data([1, 2, 3]),
                  "feature print survives a reopen")
            check(await b.entryCount() == 2, "entry count is restored")
        }

        // A real archived feature print is ~3KB of arbitrary bytes. Binary plists use
        // different length markers for small vs large data, so the toy blob above does
        // not exercise the same path. Byte-exact round-trip is what keeps distances —
        // and therefore match quality — identical to the old store.
        do {
            let dir = tempDir()
            var blob = Data(count: 3072)
            for i in blob.indices { blob[i] = UInt8.random(in: 0...255) }

            let a = CacheStore(directory: dir)
            await a.setFeaturePrint(id: "p", mtime: 1, pixelCount: 100, data: blob, revision: 2)
            await a.flushNow()

            let b = CacheStore(directory: dir)
            let out = await entry(b, "p")?.featurePrintData
            check(out == blob, "3KB feature print round-trips byte-for-byte")
            check(out?.count == 3072, "no truncation at realistic blob size")
        }

        // Vision's print format is versioned and prints from different revisions are
        // not comparable — computeDistance throws and the scan swallows it, so a
        // stale print reads as "no duplicates" rather than an error. The revision
        // must survive the round-trip and must gate reads.
        do {
            let dir = tempDir()
            let a = CacheStore(directory: dir)
            await a.setFeaturePrint(id: "p", mtime: 1, pixelCount: 100,
                                    data: Data([7, 7, 7]), revision: 2)
            await a.flushNow()

            let b = CacheStore(directory: dir)
            let e = await entry(b, "p")
            check(e?.featurePrintRevision == 2, "revision survives a reopen")
            check(e?.featurePrint(revision: 2) == Data([7, 7, 7]), "matching revision reads")
            check(e?.featurePrint(revision: 3) == nil, "bumped revision invalidates the print")
            check(e?.featurePrint(revision: 1) == nil, "older revision invalidates the print")
        }

        // A revision bump must not throw away SHA-256 hashes — those are format-free,
        // and rehashing a library is expensive.
        do {
            let dir = tempDir()
            let a = CacheStore(directory: dir)
            await a.setHash(id: "p", mtime: 1, pixelCount: 100, sha256: "abc")
            await a.setFeaturePrint(id: "p", mtime: 1, pixelCount: 100,
                                    data: Data([1]), revision: 2)
            await a.flushNow()

            let e = await entry(CacheStore(directory: dir), "p")
            check(e?.featurePrint(revision: 3) == nil, "stale print is rejected")
            check(e?.sha256 == "abc", "hash survives a revision bump")
        }

        // Entries predating revision tracking decode with nil and must not be
        // mistaken for any current revision.
        do {
            let legacy = CacheEntry(mtime: 1, pixelCount: 100, sha256: nil,
                                    featurePrintData: Data([1, 2]), featurePrintRevision: nil)
            check(legacy.featurePrint(revision: 2) == nil,
                  "unknown revision never passes as current")
        }

        // Both fields on one id must merge, not clobber.
        do {
            let dir = tempDir()
            let a = CacheStore(directory: dir)
            await a.setHash(id: "p", mtime: 1, pixelCount: 100, sha256: "abc")
            await a.setFeaturePrint(id: "p", mtime: 1, pixelCount: 100, data: Data([9]), revision: 2)
            await a.flushNow()

            let b = CacheStore(directory: dir)
            let e = await entry(b, "p")
            check(e?.sha256 == "abc" && e?.featurePrintData == Data([9]),
                  "later record merges with the earlier one")
        }

        // A kill mid-append truncates the last record. Everything before it must survive.
        do {
            let dir = tempDir()
            let log = dir.appendingPathComponent("cache.log")
            let a = CacheStore(directory: dir)
            for i in 0..<20 {
                await a.setHash(id: "photo-\(i)", mtime: 1, pixelCount: 100, sha256: "h\(i)")
            }
            await a.flushNow()

            let intact = try! Data(contentsOf: log)
            try! intact.dropLast(9).write(to: log)   // sever the final record

            let b = CacheStore(directory: dir)
            let n = await b.entryCount()
            check(n == 19, "torn final record is dropped, the other 19 survive (got \(n))")
            check(await entry(b, "photo-0")?.sha256 == "h0", "earliest record still readable")
        }

        // A stale mtime must invalidate, or an edited photo keeps a wrong fingerprint.
        do {
            let dir = tempDir()
            let a = CacheStore(directory: dir)
            await a.setHash(id: "p", mtime: 1, pixelCount: 100, sha256: "abc")
            check(await a.get(id: "p", mtime: 2, pixelCount: 100) == nil, "changed mtime misses")
            check(await a.get(id: "p", mtime: 1, pixelCount: 999) == nil, "changed size misses")
        }

        // Superseded records get compacted away at load, not during a scan.
        do {
            let dir = tempDir()
            let log = dir.appendingPathComponent("cache.log")
            let a = CacheStore(directory: dir)
            for _ in 0..<50 {
                await a.setHash(id: "same", mtime: 1, pixelCount: 100, sha256: "abc")
            }
            await a.flushNow()
            let fat = try! Data(contentsOf: log).count

            _ = CacheStore(directory: dir)              // compacts on load
            let slim = try! Data(contentsOf: log).count
            check(slim < fat, "compaction shrinks the log (\(fat) -> \(slim) bytes)")

            let c = CacheStore(directory: dir)
            check(await entry(c, "same")?.sha256 == "abc", "compaction preserves the live entry")
        }

        // Existing users must not lose their cache to the format change.
        do {
            let dir = tempDir()
            let legacy = [
                "old-1": CacheEntry(mtime: 1, pixelCount: 100, sha256: "xyz", featurePrintData: nil)
            ]
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try! encoder.encode(legacy).write(to: dir.appendingPathComponent("cache.plist"))

            let a = CacheStore(directory: dir)
            check(await entry(a, "old-1")?.sha256 == "xyz", "legacy plist is adopted")
            check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cache.plist").path),
                  "legacy plist is removed after adoption")

            let b = CacheStore(directory: dir)
            check(await entry(b, "old-1")?.sha256 == "xyz", "adopted entries persist in the log")
        }

        // clear() must not leave the store unwritable.
        do {
            let dir = tempDir()
            let a = CacheStore(directory: dir)
            await a.setHash(id: "p", mtime: 1, pixelCount: 100, sha256: "abc")
            await a.clear()
            check(await a.entryCount() == 0, "clear empties the store")
            await a.setHash(id: "q", mtime: 1, pixelCount: 100, sha256: "def")
            await a.flushNow()

            let b = CacheStore(directory: dir)
            check(await entry(b, "q")?.sha256 == "def", "writes after clear still persist")
            check(await entry(b, "p") == nil, "cleared entries stay gone")
        }

        print("\nall checks passed")
    }
}
