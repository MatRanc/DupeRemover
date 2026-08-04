import Foundation
import Testing
@testable import DupeRemover

/// The folder source: what a scan sees before any grouping happens.
@Suite("File source")
struct FileSourceTests {

    @Test("picks up images recursively and skips everything else")
    func enumeration() throws {
        let dir = TestImages.tempDir("enum")
        let nested = dir.appendingPathComponent("holiday/2026")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        TestImages.write(.beach, to: dir, named: "a.png")
        TestImages.write(.forest, to: nested, named: "b.JPG")
        TestImages.write(.portrait, to: nested, named: "c.heic")
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("neither".utf8).write(to: dir.appendingPathComponent(".hidden.png"))

        let items = FileSource.enumerate([dir])
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.localURL != nil })
        #expect(items.allSatisfy { $0.token > 0 })
        #expect(items.contains { $0.name == "b.JPG" })      // extension match is case-insensitive
        #expect(!items.contains { $0.name == "notes.txt" })
        #expect(!items.contains { $0.name == ".hidden.png" })
    }

    @Test("scanning several folders at once returns all of them")
    func multipleFolders() {
        let a = TestImages.tempDir("enum-a")
        let b = TestImages.tempDir("enum-b")
        TestImages.write(.beach, to: a, named: "one.png")
        TestImages.write(.forest, to: b, named: "two.png")

        let items = FileSource.enumerate([a, b])
        #expect(items.count == 2)
        #expect(Set(items.map(\.name)) == ["one.png", "two.png"])
    }

    @Test("byte size is the collision key, so copies collide and others don't")
    func tokenIsByteSize() throws {
        let dir = TestImages.tempDir("token")
        let original = TestImages.write(.beach, to: dir, named: "a.png")
        TestImages.copy(original, to: "copy.png")
        TestImages.write(.cityscape, to: dir, named: "other.png")

        let byName = Dictionary(uniqueKeysWithValues: FileSource.enumerate([dir]).map { ($0.name, $0) })
        let realSize = try FileManager.default.attributesOfItem(atPath: original.path)[.size] as! Int64
        #expect(byName["a.png"]!.token == realSize)
        #expect(byName["a.png"]!.token == byName["copy.png"]!.token)
        #expect(byName["a.png"]!.token != byName["other.png"]!.token)
    }

    @Test("identical bytes hash identically, different bytes don't")
    func hashing() {
        let dir = TestImages.tempDir("hash")
        let original = TestImages.write(.beach, to: dir, named: "a.png")
        let copy = TestImages.copy(original, to: "copy.png")
        let other = TestImages.write(.forest, to: dir, named: "other.png")

        #expect(FileSource.sha256(of: original) == FileSource.sha256(of: copy))
        #expect(FileSource.sha256(of: original) != FileSource.sha256(of: other))
        #expect(FileSource.sha256(of: original)?.count == 64)
    }

    @Test("a missing file yields nil rather than crashing the scan")
    func missingFile() {
        let gone = TestImages.tempDir("gone").appendingPathComponent("nope.png")
        #expect(FileSource.sha256(of: gone) == nil)
        #expect(FileSource.cgImage(at: gone, maxPixel: 448) == nil)
    }

    @Test("a file with an image extension but garbage inside is skipped, not fatal")
    func corruptFile() throws {
        let dir = TestImages.tempDir("corrupt")
        try Data(repeating: 0xAB, count: 4096).write(to: dir.appendingPathComponent("broken.png"))
        TestImages.write(.beach, to: dir, named: "good.png")

        let items = FileSource.enumerate([dir])
        #expect(items.count == 2)                       // enumeration doesn't decode
        let broken = items.first { $0.name == "broken.png" }!
        #expect(FileSource.cgImage(at: broken.localURL!, maxPixel: 448) == nil)
        #expect(FileSource.sha256(of: broken.localURL!) != nil)   // hashing still works
    }

    /// Decoding 40MP originals whole is exactly the cost this path exists to
    /// avoid, and it is also what keeps prints comparable with the Photos side.
    @Test("the Vision input is downscaled, not decoded whole")
    func downscaling() {
        let dir = TestImages.tempDir("scale")
        let big = TestImages.write(.cityscape, to: dir, named: "big.png", size: 1600)
        let cg = FileSource.cgImage(at: big, maxPixel: visionInputPixel)
        #expect(cg != nil)
        #expect(max(cg!.width, cg!.height) <= Int(visionInputPixel))
        #expect(max(cg!.width, cg!.height) > 100)       // not degenerate
    }

    @Test("an empty folder yields nothing and doesn't throw")
    func emptyFolder() {
        #expect(FileSource.enumerate([TestImages.tempDir("empty")]).isEmpty)
    }
}
