import Foundation
import Vision
@testable import DupeRemover

enum TestSupport {
    /// The iOS Simulator has no Neural Engine, and
    /// `VNGenerateImageFeaturePrintRequest` returns no result there — every
    /// similar-photo test would fail for a reason that has nothing to do with
    /// this app. Tests that need a real print are gated on this, so a simulator
    /// run still covers enumeration, hashing, identical detection, the cache and
    /// deletion, and a run on a Mac or a real device covers everything.
    ///
    /// Probed once, on a tiny image, rather than assumed from `#if targetEnvironment`.
    static let visionAvailable: Bool = {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return computeFeaturePrint(from: ctx.makeImage()!) != nil
    }()
}
