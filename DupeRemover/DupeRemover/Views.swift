import SwiftUI
import Photos

// MARK: - Asset row

struct AssetRow: View {
    let asset: PhotoAsset
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            AssetThumbnail(assetID: asset.id, pointSize: 56)
                .frame(width: 56, height: 56)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.subtitle(for: asset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .contextMenu {
            Button {
                onToggle()
            } label: {
                Label(isSelected ? "Deselect" : "Select",
                      systemImage: isSelected ? "circle" : "checkmark.circle")
            }
        } preview: {
            AssetPreview(asset: asset)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    /// "4032×3024 · 2.4 MB · Jun 5, 2026 at 12:03". File size is omitted when
    /// unknown (e.g. iCloud-only originals report no local size).
    private static func subtitle(for asset: PhotoAsset) -> String {
        var parts = ["\(asset.pixelWidth)×\(asset.pixelHeight)"]
        if asset.byteSize > 0 {
            parts.append(byteFormatter.string(fromByteCount: asset.byteSize))
        }
        parts.append(dateText(asset.creationDate))
        return parts.joined(separator: " · ")
    }

    private static func dateText(_ epoch: Double) -> String {
        guard epoch > 0 else { return "Unknown date" }
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}

// MARK: - Thumbnail

struct AssetThumbnail: View {
    let assetID: String
    let pointSize: CGFloat
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: assetID) {
            image = await PhotoLibrary.thumbnail(
                forAssetID: assetID,
                pointSize: pointSize,
                scale: displayScale
            )
        }
    }
}

// MARK: - Large preview (long-press / Haptic Touch)

struct AssetPreview: View {
    let asset: PhotoAsset
    @State private var image: UIImage?

    // Cap the longest edge; height/width follow the photo's real aspect ratio so
    // the preview isn't letterboxed.
    private var previewSize: CGSize {
        let maxDim: CGFloat = 320
        let w = CGFloat(max(asset.pixelWidth, 1))
        let h = CGFloat(max(asset.pixelHeight, 1))
        return w >= h
            ? CGSize(width: maxDim, height: maxDim * h / w)
            : CGSize(width: maxDim * w / h, height: maxDim)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color(.secondarySystemBackground)
                    .overlay { ProgressView() }
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .task(id: asset.id) {
            // Drop any image from a previously shown asset so we never display the
            // wrong photo; the low-res delivery fills in almost immediately.
            image = nil
            for await stage in PhotoLibrary.previewImages(forAssetID: asset.id, maxPixel: 1200) {
                image = stage
            }
        }
    }
}

// MARK: - Permission gate

struct PermissionView: View {
    let status: PHAuthorizationStatus
    let onRequest: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Find duplicate photos")
                .font(.title2).fontWeight(.semibold)

            Text("Dupe Remover needs access to your photo library to compare images and group duplicates. Everything is analyzed on your device — nothing is uploaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if status == .denied || status == .restricted {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Text("Photo access is off. Enable it in Settings to scan your library.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                Button("Grant photo access", action: onRequest)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Album picker

struct AlbumPickerSheet: View {
    let albums: [AlbumOption]
    let selectedID: String?
    let onSelect: (AlbumOption?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "Entire library", count: nil, isSelected: selectedID == nil) {
                        onSelect(nil); dismiss()
                    }
                }
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums) { album in
                            row(title: album.title, count: album.count, isSelected: selectedID == album.id) {
                                onSelect(album); dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan scope")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(title: String, count: Int?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let count {
                    Text("\(count)").foregroundStyle(.secondary)
                }
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }
}

// MARK: - About

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// App Store numeric ID, used to deep-link to the review page.
    // TODO: replace with the real App Store ID once the app is live.
    private static let appStoreID = "0000000000"
    /// Address feedback is sent to.
    private static let feedbackEmail = "matranc03+duperemover@gmail.com"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let icon = UIImage(named: "AboutIcon") {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                            .shadow(radius: 4, y: 2)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                    }

                    VStack(spacing: 4) {
                        Text("Dupe Remover")
                            .font(.title2).fontWeight(.semibold)
                        Text("Version \(version) (\(build))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Text("Finds duplicate and visually similar photos in your library and lets you move the extras to Recently Deleted. Everything runs on your device — nothing is uploaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Text("Made in 🇨🇦 with ❤️")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        Button(action: rateApp) {
                            Label("Rate App", systemImage: "star")
                        }
                        Button(action: sendFeedback) {
                            Label("Send Feedback", systemImage: "envelope")
                        }
                    }
                    .font(.callout)
                    .padding(.top, 4)

                    VStack(spacing: 12) {
                        Link(destination: URL(string: "https://github.com/MatRanc/DupeRemoveriOS")!) {
                            Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Link(destination: URL(string: "https://github.com/MatRanc/DupeRemoveriOS/blob/main/PRIVACY.md")!) {
                            Label("Privacy policy", systemImage: "hand.raised")
                        }
                        Link(destination: URL(string: "https://www.flaticon.com/free-icon/duplicate_3991529")!) {
                            Label("App icon by Flaticon", systemImage: "app.gift")
                        }
                    }
                    .font(.callout)
                    .padding(.top, 4)

                    Text("© 2026 Mathieu Rancourt · MIT License")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func rateApp() {
        let urlString = "itms-apps://apps.apple.com/app/id\(Self.appStoreID)?action=write-review"
        if let url = URL(string: urlString) { openURL(url) }
    }

    private func sendFeedback() {
        let subject = "Dupe Remover Feedback"
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        if let url = URL(string: "mailto:\(Self.feedbackEmail)?subject=\(encodedSubject)") {
            openURL(url)
        }
    }
}

// MARK: - Match info

struct MatchInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(
                        "Identical",
                        "Compares photos byte-for-byte. Catches exact duplicates: the same photo saved twice or imported more than once. Fast and 100% reliable, but won't catch a photo that's been re-saved, resized, or edited — even one changed pixel makes it a different file."
                    )
                    section(
                        "Also match similar photos",
                        "Uses Apple's on-device Vision framework to compare what photos look like, not how they're stored. Catches re-exported JPEGs, light edits, the same shot at different resolutions, or screenshots of the same image. Slower the first time because each photo is analyzed once — results are cached so repeat scans are fast."
                    )
                    section(
                        "Strictness slider",
                        "Controls how visually close two photos must be before they're grouped. Lower = stricter (only photos that look almost identical). Higher = looser (catches more edited/cropped variants but risks false matches). 20% works well for most libraries."
                    )

                    Text("Both modes run entirely on your device. Nothing is uploaded.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("How matching works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
    }
}
