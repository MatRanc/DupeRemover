import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Dummy images with enough structure that Vision's feature prints mean
/// something: a flat colour field would make every "similar" assertion vacuous.
/// Each subject draws deterministically from its seed, so the same subject
/// rendered at two sizes or two formats is genuinely the same picture, and two
/// different subjects genuinely differ.
enum TestImages {

    enum Subject: CaseIterable {
        case beach       // warm sky over sand, one sun
        case forest      // green columns on dark ground
        case cityscape   // grey blocks with lit windows
        case portrait    // skin-toned oval on a plain backdrop
    }

    // MARK: Files

    static func tempDir(_ label: String = "scan") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupetest-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `subject` into `directory` as `name`. The format follows the file
    /// extension: .png is lossless, .jpg/.jpeg honours `quality`, .heic exercises
    /// the format most iPhone photos actually arrive in.
    @discardableResult
    static func write(
        _ subject: Subject,
        to directory: URL,
        named name: String,
        size: Int = 512,
        quality: Double = 0.9
    ) -> URL {
        let url = directory.appendingPathComponent(name)
        let image = render(subject, size: size)
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": type = .jpeg
        case "heic": type = .heic
        default: type = .png
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil) else {
            fatalError("cannot create image destination for \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            fatalError("cannot encode \(url.lastPathComponent) as \(type.identifier)")
        }
        return url
    }

    /// A byte-for-byte copy — what an import-twice duplicate really looks like.
    @discardableResult
    static func copy(_ url: URL, to name: String) -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try! FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    // MARK: Drawing

    static func render(_ subject: Subject, size: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let s = CGFloat(size)

        func fill(_ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
            ctx.fill(rect)
        }
        func ellipse(_ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
            ctx.fillEllipse(in: rect)
        }

        switch subject {
        case .beach:
            fill(CGRect(x: 0, y: 0, width: s, height: s), 0.42, 0.72, 0.95)          // sky
            fill(CGRect(x: 0, y: 0, width: s, height: s * 0.35), 0.93, 0.85, 0.62)   // sand
            fill(CGRect(x: 0, y: s * 0.35, width: s, height: s * 0.12), 0.13, 0.45, 0.72) // sea
            ellipse(CGRect(x: s * 0.62, y: s * 0.72, width: s * 0.18, height: s * 0.18),
                    1.0, 0.94, 0.55)                                                 // sun

        case .forest:
            fill(CGRect(x: 0, y: 0, width: s, height: s), 0.07, 0.22, 0.10)
            for i in 0..<6 {
                let x = s * (0.06 + 0.155 * CGFloat(i))
                fill(CGRect(x: x, y: s * 0.12, width: s * 0.06, height: s * 0.78),
                     0.32, 0.20, 0.09)                                               // trunks
                ellipse(CGRect(x: x - s * 0.05, y: s * 0.55, width: s * 0.16, height: s * 0.30),
                        0.16, 0.48 + 0.05 * CGFloat(i % 3), 0.18)                    // canopy
            }
            fill(CGRect(x: 0, y: 0, width: s, height: s * 0.14), 0.20, 0.16, 0.08)   // ground

        case .cityscape:
            fill(CGRect(x: 0, y: 0, width: s, height: s), 0.10, 0.12, 0.20)
            for i in 0..<7 {
                let h = s * (0.30 + 0.09 * CGFloat((i * 3) % 5))
                let x = s * (0.03 + 0.138 * CGFloat(i))
                fill(CGRect(x: x, y: 0, width: s * 0.11, height: h), 0.28, 0.30, 0.36)
                for row in 0..<Int(h / (s * 0.08)) where (row + i) % 2 == 0 {
                    fill(CGRect(x: x + s * 0.02, y: CGFloat(row) * s * 0.08 + s * 0.03,
                                width: s * 0.03, height: s * 0.03),
                         0.98, 0.90, 0.55)                                           // windows
                }
            }

        case .portrait:
            fill(CGRect(x: 0, y: 0, width: s, height: s), 0.85, 0.86, 0.88)
            ellipse(CGRect(x: s * 0.28, y: s * 0.30, width: s * 0.44, height: s * 0.55),
                    0.90, 0.74, 0.62)                                                // face
            ellipse(CGRect(x: s * 0.38, y: s * 0.62, width: s * 0.07, height: s * 0.05), 0.15, 0.12, 0.10)
            ellipse(CGRect(x: s * 0.55, y: s * 0.62, width: s * 0.07, height: s * 0.05), 0.15, 0.12, 0.10)
            fill(CGRect(x: s * 0.40, y: s * 0.42, width: s * 0.20, height: s * 0.03), 0.55, 0.25, 0.25)
        }

        return ctx.makeImage()!
    }
}
