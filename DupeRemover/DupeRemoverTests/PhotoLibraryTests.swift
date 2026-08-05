import Foundation
import Photos
import Testing
@testable import DupeRemover

/// The library fetch itself needs a real Photos library, so what's testable here
/// is the options it goes out with — which is exactly where it broke.
@Suite("Photo library fetch")
struct PhotoLibraryTests {

    /// A library-wide fetch quietly filters to `typeUserLibrary` unless every source
    /// is named. On a Mac using an iCloud Shared Library that returned nothing at
    /// all while albums listed tens of thousands of photos.
    @Test("the image fetch asks for every asset source")
    func includesEveryAssetSource() {
        let sources = PhotoLibrary.imageFetchOptions().includeAssetSourceTypes
        #expect(sources.contains(.typeUserLibrary))
        #expect(sources.contains(.typeCloudShared))
        #expect(sources.contains(.typeiTunesSynced))
    }

    /// The scope sheet shows "Entire library" as personal + shared, so the two have
    /// to partition the library exactly — no photo counted twice, none missed.
    @Test("personal and shared split the library between them")
    func sourcesPartitionTheLibrary() {
        #expect(PhotoLibrary.personalSources.isDisjoint(with: PhotoLibrary.sharedSources))
        #expect(PhotoLibrary.personalSources.union(PhotoLibrary.sharedSources)
                == PhotoLibrary.allSources)
    }

    @Test("a scoped fetch narrows the sources, an album fetch doesn't")
    func scopeChoosesSources() {
        #expect(PhotoLibrary.imageFetchOptions(sources: PhotoLibrary.sharedSources)
                .includeAssetSourceTypes == PhotoLibrary.sharedSources)
        #expect(PhotoLibrary.imageFetchOptions(sources: PhotoLibrary.personalSources)
                .includeAssetSourceTypes == PhotoLibrary.personalSources)
    }

    /// `fileSize` and `locallyAvailable` are read off `PHAssetResource` by KVC —
    /// neither is public API. `locallyAvailable` is the one that decides whether a
    /// photo is even attempted, and a missing key reads as "available", so a rename
    /// wouldn't crash: it would quietly put every iCloud-only original back into the
    /// hash queue to fail again on every scan. That is the bug it was added to fix,
    /// so pin the names to the runtime rather than to our memory of them.
    @Test("the private resource keys we read still exist", arguments: ["fileSize", "locallyAvailable"])
    func kvcKeysExistOnAssetResource(key: String) {
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(PHAssetResource.self, &count) else {
            Issue.record("PHAssetResource exposes no properties at all")
            return
        }
        defer { free(list) }
        let names = (0..<Int(count)).map { String(cString: property_getName(list[$0])) }
        #expect(names.contains(key), "PHAssetResource no longer has '\(key)': \(names.sorted())")
    }

    @Test("the image fetch asks for images, newest first")
    func fetchesImagesNewestFirst() {
        let options = PhotoLibrary.imageFetchOptions()
        #expect(options.predicate == NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        #expect(options.sortDescriptors == [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ])
    }
}

/// The gate that stops a hash request from hanging the scan forever. A real hang
/// needs a photo Photos never calls back for, which no test can conjure — but the
/// gate is the part that has to be right, and resuming a checked continuation twice
/// traps the process, so this is a crash test as much as an assertion.
@Suite("Hash request resume gate")
struct ResumeOnceTests {

    /// The completion handler, the 30s deadline and Cancel can all land together.
    @Test("only the first finisher resumes the continuation")
    func resumesOnceUnderContention() async {
        let gate = ResumeOnce()
        var winners = 0
        let lock = NSLock()

        let value: String? = await withCheckedContinuation { continuation in
            gate.hold(continuation)
            DispatchQueue.concurrentPerform(iterations: 32) { i in
                if gate.finish(i == 0 ? "digest" : nil) {
                    lock.lock(); winners += 1; lock.unlock()
                }
            }
        }
        _ = value
        #expect(winners == 1)
    }

    /// Cancel can arrive before the request is even issued. The continuation is
    /// installed after that, and still has to be resumed or the scan waits forever.
    @Test("finishing before the continuation arrives still resumes it")
    func resumesWhenCancelledFirst() async {
        let gate = ResumeOnce()
        #expect(gate.finish("ignored"))

        let value: String? = await withCheckedContinuation { continuation in
            gate.hold(continuation)
        }
        #expect(value == nil)
    }

    /// The ordinary path: the request completes and its digest is what comes back.
    @Test("a completed request hands back its digest")
    func deliversTheDigest() async {
        let gate = ResumeOnce()
        let value: String? = await withCheckedContinuation { continuation in
            gate.hold(continuation)
            DispatchQueue.global().async { gate.finish("digest") }
        }
        #expect(value == "digest")
    }
}
