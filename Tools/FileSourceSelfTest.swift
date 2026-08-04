// Self-check for the local-folder source. No test target needed (macOS only,
// since it compiles the app's non-UI files directly):
//
//   swiftc -parse-as-library DupeRemover/DupeRemover/Cache.swift \
//       DupeRemover/DupeRemover/ScanItem.swift \
//       DupeRemover/DupeRemover/PhotoLibrary.swift \
//       DupeRemover/DupeRemover/FileSource.swift \
//       Tools/FileSourceSelfTest.swift -o /tmp/filecheck && /tmp/filecheck
//
// Covers what the folder scan actually depends on: only image files are picked
// up, recursively; byte size becomes the change token so two copies collide;
// hashing agrees for identical bytes and differs for different ones; and the
// Vision input is really downscaled instead of decoded whole.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func check(_ condition: Bool, _ what: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
        exit(1)
    }
    print("ok — \(what)")
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("filecheck-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A real PNG of `size`×`size`, so ImageIO has something genuine to downscale.
@discardableResult
func writePNG(_ url: URL, size: Int, gray: CGFloat) -> URL {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return url
}

@main
struct FileSourceSelfTest {
    static func main() {

        // Only images, and only real files — recursively, skipping everything else.
        do {
            let dir = tempDir()
            let nested = dir.appendingPathComponent("sub/deeper")
            try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            writePNG(dir.appendingPathComponent("a.png"), size: 64, gray: 0.2)
            writePNG(nested.appendingPathComponent("b.PNG"), size: 64, gray: 0.4)
            try! Data("not an image".utf8).write(to: dir.appendingPathComponent("notes.txt"))

            let items = FileSource.enumerate([dir])
            check(items.count == 2, "picks up 2 images across subfolders (got \(items.count))")
            check(items.allSatisfy { $0.localURL != nil }, "every item carries its file URL")
            check(!items.contains { $0.name == "notes.txt" }, "non-image extensions are skipped")
            check(items.contains { $0.name == "b.PNG" }, "extension match is case-insensitive")
        }

        // Byte size is both the identical-detection collision key and the cache's
        // change token, so two copies of one file must agree on it and a different
        // image must not.
        do {
            let dir = tempDir()
            let a = writePNG(dir.appendingPathComponent("a.png"), size: 64, gray: 0.2)
            let copy = dir.appendingPathComponent("copy.png")
            try! FileManager.default.copyItem(at: a, to: copy)
            let other = writePNG(dir.appendingPathComponent("other.png"), size: 128, gray: 0.9)

            let items = FileSource.enumerate([dir]).sorted { $0.name < $1.name }
            let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
            check(byName["a.png"]!.token == byName["copy.png"]!.token, "a copy shares the token")
            check(byName["a.png"]!.token > 0, "token is the real byte size")
            check(byName["other.png"]!.token != byName["a.png"]!.token,
                  "a different image gets a different token")

            check(FileSource.sha256(of: a) == FileSource.sha256(of: copy),
                  "identical bytes hash identically")
            check(FileSource.sha256(of: a) != FileSource.sha256(of: other),
                  "different bytes hash differently")
            check(FileSource.sha256(of: dir.appendingPathComponent("gone.png")) == nil,
                  "a missing file hashes to nil, not a crash")
        }

        // The Vision input must come back downscaled: decoding 40MP originals whole
        // is exactly the cost this path exists to avoid.
        do {
            let dir = tempDir()
            let big = writePNG(dir.appendingPathComponent("big.png"), size: 1200, gray: 0.5)
            let cg = FileSource.cgImage(at: big, maxPixel: 448)
            check(cg != nil, "produces a CGImage")
            check(max(cg!.width, cg!.height) <= 448,
                  "long edge is capped at 448 (got \(cg!.width)×\(cg!.height))")
            check(FileSource.cgImage(at: dir.appendingPathComponent("gone.png"), maxPixel: 448) == nil,
                  "a missing file yields nil, not a crash")
        }

        print("\nall checks passed")
    }
}
