import Foundation
import Vision

// One cache record per photo, keyed by the asset's stable localIdentifier.
// `mtime` and `pixelCount` together act as a change token: if the photo is
// edited (modification date moves) or replaced, the cached hash / feature print
// is treated as stale and recomputed.
nonisolated struct CacheEntry: Codable, Sendable {
    var mtime: Double
    var pixelCount: Int64
    var sha256: String?
    var featurePrintData: Data?
    // Which Vision revision produced `featurePrintData`. nil for entries written
    // before this was tracked. Not part of the mtime/pixelCount staleness check —
    // a revision bump must not throw away perfectly good SHA-256 hashes.
    var featurePrintRevision: Int?

    /// The stored print, but only when it is comparable with `revision`. Vision's
    /// feature-print format is versioned and `computeDistance` throws across
    /// versions — which the scan swallows, so a mismatch silently degrades into
    /// "no duplicates found" rather than an error.
    ///
    /// Returns nil for unknown (legacy) revisions too; the caller decides whether
    /// unarchiving to find out beats recomputing.
    func featurePrint(revision: Int) -> Data? {
        guard featurePrintRevision == revision else { return nil }
        return featurePrintData
    }
}

/// Append-only record log.
///
/// The previous design rewrote the entire store on every save. That is O(cache)
/// per write: at 32k entries a save re-encoded ~100MB of plist to record a couple
/// thousand new photos, measured at 10-30s and growing with each checkpoint —
/// O(n²) over a scan. Appending one length-prefixed record instead is O(1), so the
/// cost no longer depends on how much is already cached, and each entry becomes
/// durable the moment it is computed rather than at the next checkpoint.
///
/// Superseded records accumulate (a photo hashed and then fingerprinted writes
/// two), so the log is compacted — but only at load, never mid-scan, since that is
/// the one moment when an O(n) pass costs the user nothing.
actor CacheStore {
    private var entries: [String: CacheEntry]
    private var recordCount: Int
    private var handle: FileHandle?
    private let fileURL: URL

    private struct Record: Codable {
        let id: String
        let entry: CacheEntry
    }

    /// `directory` exists so the self-check can drive a real store in a temp dir.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(Bundle.main.bundleIdentifier ?? "DupeRemover")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cache.log")
        self.fileURL = url

        var (loaded, count) = Self.replayLog(at: url)
        if loaded.isEmpty, let legacy = Self.readLegacyPlist(in: dir) {
            loaded = legacy
            count = Self.rewriteLog(legacy, to: url)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("cache.plist"))
        } else if count > loaded.count + loaded.count / 2 {
            // Enough superseded records to be worth one O(n) pass, at the only
            // moment it costs the user nothing.
            count = Self.rewriteLog(loaded, to: url)
        }

        self.entries = loaded
        self.recordCount = count
        self.handle = Self.openForAppending(url)
    }

    // MARK: Reads

    func get(id: String, mtime: Double, pixelCount: Int64) -> CacheEntry? {
        guard let e = entries[id],
              abs(e.mtime - mtime) < 0.001,
              e.pixelCount == pixelCount else { return nil }
        return e
    }

    func entryCount() -> Int { entries.count }

    func diskSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    // MARK: Writes

    func setHash(id: String, mtime: Double, pixelCount: Int64, sha256: String) {
        var e = freshEntryIfStale(id: id, mtime: mtime, pixelCount: pixelCount)
        e.sha256 = sha256
        entries[id] = e
        append(id: id, entry: e)
    }

    func setFeaturePrint(id: String, mtime: Double, pixelCount: Int64, data: Data, revision: Int) {
        var e = freshEntryIfStale(id: id, mtime: mtime, pixelCount: pixelCount)
        e.featurePrintData = data
        e.featurePrintRevision = revision
        entries[id] = e
        append(id: id, entry: e)
    }

    private func freshEntryIfStale(id: String, mtime: Double, pixelCount: Int64) -> CacheEntry {
        if let e = entries[id], abs(e.mtime - mtime) < 0.001, e.pixelCount == pixelCount {
            return e
        }
        return CacheEntry(mtime: mtime, pixelCount: pixelCount, sha256: nil, featurePrintData: nil)
    }

    private func append(id: String, entry: CacheEntry) {
        autoreleasepool {
            guard let blob = Self.encode(Record(id: id, entry: entry)) else { return }
            try? handle?.write(contentsOf: Self.framed(blob))
            recordCount += 1
        }
    }

    /// Records reach the file on every write; this only forces the OS to flush its
    /// buffers, so a phase boundary survives an abrupt kill.
    func flushNow() {
        try? handle?.synchronize()
    }

    func clear() {
        entries = [:]
        recordCount = 0
        try? handle?.close()
        try? FileManager.default.removeItem(at: fileURL)
        handle = Self.openForAppending(fileURL)
    }

    // MARK: Log format
    //
    // A record is a 4-byte little-endian payload length followed by a binary plist
    // of `Record`. Everything below is a pure function of its arguments so `init`
    // can use it before the actor exists.

    private nonisolated static func encode(_ record: Record) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(record)
    }

    private nonisolated static func framed(_ blob: Data) -> Data {
        var length = UInt32(blob.count).littleEndian
        var out = Data(bytes: &length, count: 4)
        out.append(blob)
        return out
    }

    private nonisolated static func replayLog(at url: URL) -> ([String: CacheEntry], Int) {
        guard let data = try? Data(contentsOf: url) else { return ([:], 0) }
        let decoder = PropertyListDecoder()
        var entries: [String: CacheEntry] = [:]
        var count = 0
        var offset = 0
        while offset + 4 <= data.count {
            let length = Int(data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }.littleEndian)
            let start = offset + 4
            // A process killed mid-append leaves a torn final record. Stop there and
            // keep everything written before it — that is the point of the log.
            guard length > 0, start + length <= data.count else { break }
            if let r = try? decoder.decode(Record.self, from: Data(data[start..<(start + length)])) {
                entries[r.id] = r.entry
                count += 1
            }
            offset = start + length
        }
        return (entries, count)
    }

    /// Rewrites the log so it holds exactly one record per live entry. Returns the
    /// new record count, or the entry count unchanged if the rewrite failed.
    private nonisolated static func rewriteLog(
        _ entries: [String: CacheEntry], to url: URL
    ) -> Int {
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmp) else { return entries.count }

        var written = 0
        for (id, entry) in entries {
            autoreleasepool {
                guard let blob = encode(Record(id: id, entry: entry)) else { return }
                try? out.write(contentsOf: framed(blob))
                written += 1
            }
        }
        try? out.close()

        guard (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil else {
            try? FileManager.default.removeItem(at: tmp)
            return entries.count
        }
        return written
    }

    /// One-time upgrade from the old whole-file plist, so nobody loses cached work.
    private nonisolated static func readLegacyPlist(in dir: URL) -> [String: CacheEntry]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("cache.plist"))
        else { return nil }
        return try? PropertyListDecoder().decode([String: CacheEntry].self, from: data)
    }

    private nonisolated static func openForAppending(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
