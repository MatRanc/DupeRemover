import Foundation
import Vision

nonisolated struct CacheEntry: Codable, Sendable {
    var mtime: Double
    var size: Int64
    var sha256: String?
    var featurePrintData: Data?
}

actor CacheStore {
    private var entries: [String: CacheEntry] = [:]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "PhotoDuplicateFinder"
        let dir = support.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cache.plist")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? PropertyListDecoder().decode([String: CacheEntry].self, from: data) {
            entries = decoded
        }
    }

    func get(path: String, mtime: Double, size: Int64) -> CacheEntry? {
        guard let e = entries[path],
              abs(e.mtime - mtime) < 0.001,
              e.size == size else { return nil }
        return e
    }

    func setHash(path: String, mtime: Double, size: Int64, sha256: String) {
        var e = entries[path] ?? CacheEntry(mtime: mtime, size: size, sha256: nil, featurePrintData: nil)
        if abs(e.mtime - mtime) > 0.001 || e.size != size {
            e = CacheEntry(mtime: mtime, size: size, sha256: nil, featurePrintData: nil)
        }
        e.sha256 = sha256
        entries[path] = e
        scheduleSave()
    }

    func setFeaturePrint(path: String, mtime: Double, size: Int64, data: Data) {
        var e = entries[path] ?? CacheEntry(mtime: mtime, size: size, sha256: nil, featurePrintData: nil)
        if abs(e.mtime - mtime) > 0.001 || e.size != size {
            e = CacheEntry(mtime: mtime, size: size, sha256: nil, featurePrintData: nil)
        }
        e.featurePrintData = data
        entries[path] = e
        scheduleSave()
    }

    func entryCount() -> Int { entries.count }

    func diskSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    func clear() {
        entries = [:]
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func flushNow() {
        saveTask?.cancel()
        persist()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    private func persist() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

