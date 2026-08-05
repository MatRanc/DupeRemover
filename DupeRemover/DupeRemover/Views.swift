import SwiftUI
import Photos
#if os(macOS)
import AppKit
#endif

// MARK: - Platform glue

extension Image {
    init(platform image: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

extension View {
    /// `.navigationBarTitleDisplayMode` is iOS-only; macOS has no equivalent.
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - Item row

struct ItemRow: View {
    let item: ScanItem
    let isSelected: Bool
    let onToggle: () -> Void
    #if os(iOS)
    @State private var showingInfo = false
    #endif

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            ItemThumbnail(item: item, pointSize: 56)
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.subtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            #if os(macOS)
            if item.byteSize > 0 {
                Text(formatBytes(item.byteSize))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let url = item.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            #endif
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        #if os(iOS)
        // Two photos in a group look identical by definition; the useful question is
        // where each one lives. Swipe rather than a permanent button, so the row
        // stays a thumbnail and a name.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                showingInfo = true
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .tint(.blue)
        }
        .sheet(isPresented: $showingInfo) { ItemInfoSheet(item: item) }
        .contextMenu {
            Button {
                onToggle()
            } label: {
                Label(isSelected ? "Deselect" : "Select",
                      systemImage: isSelected ? "circle" : "checkmark.circle")
            }
        } preview: {
            ItemPreview(item: item)
        }
        #endif
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

    /// "4032×3024 · 2.4 MB · Jun 5, 2026 at 12:03" for a library photo; the
    /// containing folder for a file, which is what tells two copies apart.
    /// Unknown parts are left out — iCloud-only originals report no size, and
    /// files are never decoded just to learn their dimensions.
    private static func subtitle(for item: ScanItem) -> String {
        if let url = item.localURL {
            return url.deletingLastPathComponent().path
        }
        var parts: [String] = []
        if item.pixelWidth > 0, item.pixelHeight > 0 {
            parts.append("\(item.pixelWidth)×\(item.pixelHeight)")
        }
        if item.byteSize > 0 {
            parts.append(byteFormatter.string(fromByteCount: item.byteSize))
        }
        parts.append(dateText(item.creationDate))
        return parts.joined(separator: " · ")
    }

    private static func dateText(_ epoch: Double) -> String {
        guard epoch > 0 else { return "Unknown date" }
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}

// MARK: - Thumbnail

struct ItemThumbnail: View {
    let item: ScanItem
    let pointSize: CGFloat
    @State private var image: PlatformImage?
    #if os(iOS)
    @Environment(\.displayScale) private var displayScale
    #endif

    private var scale: CGFloat {
        #if os(iOS)
        displayScale
        #else
        NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }

    var body: some View {
        Group {
            if let image {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: item.id) {
            switch item.source {
            case .file(let url):
                image = await FileSource.thumbnail(at: url, pointSize: pointSize, scale: scale)
            case .asset(let id):
                image = await PhotoLibrary.thumbnail(forAssetID: id, pointSize: pointSize, scale: scale)
            }
        }
    }
}

// MARK: - Large preview (long-press / Haptic Touch)

#if os(iOS)
struct ItemPreview: View {
    let item: ScanItem
    @State private var image: PlatformImage?

    // Cap the longest edge; height/width follow the photo's real aspect ratio so
    // the preview isn't letterboxed. Files report no dimensions, so they land on
    // the square fallback.
    private var previewSize: CGSize {
        let maxDim: CGFloat = 320
        let w = CGFloat(max(item.pixelWidth, 1))
        let h = CGFloat(max(item.pixelHeight, 1))
        return w >= h
            ? CGSize(width: maxDim, height: maxDim * h / w)
            : CGSize(width: maxDim * w / h, height: maxDim)
    }

    var body: some View {
        Group {
            if let image {
                Image(platform: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color(.secondarySystemBackground)
                    .overlay { ProgressView() }
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .task(id: item.id) {
            // Drop any image from a previously shown item so we never display the
            // wrong photo; the low-res delivery fills in almost immediately.
            image = nil
            switch item.source {
            case .asset(let id):
                for await stage in PhotoLibrary.previewImages(forAssetID: id, maxPixel: 1200) {
                    image = stage
                }
            case .file(let url):
                image = await FileSource.thumbnail(at: url, pointSize: 320, scale: 2)
            }
        }
    }
}
#endif

// MARK: - Where a photo lives

#if os(iOS)
/// Swiped up from a result row. Answers the one thing the thumbnail can't: which
/// library or folder this particular copy came from.
struct ItemInfoSheet: View {
    let item: ScanItem
    @Environment(\.dismiss) private var dismiss
    @State private var placement: AssetPlacement?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if let url = item.localURL {
                    Section("Folder") {
                        Text(url.deletingLastPathComponent().path)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                } else if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking it up…").foregroundStyle(.secondary)
                    }
                } else if let placement {
                    Section("Library") {
                        Text(placement.source)
                    }
                    Section("Albums") {
                        if placement.albums.isEmpty {
                            Text("Not in any album").foregroundStyle(.secondary)
                        } else {
                            ForEach(placement.albums, id: \.self) { Text($0) }
                        }
                    }
                } else {
                    Text("This photo is no longer in the library.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(item.name)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            guard case .asset(let id) = item.source else { isLoading = false; return }
            placement = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.placement(forAssetID: id)
            }.value
            isLoading = false
        }
    }
}
#endif

// MARK: - Permission gate

struct PermissionView: View {
    let status: PHAuthorizationStatus
    let onRequest: () -> Void

    private static let settingsHint: String = {
        #if os(iOS)
        "Photo access is off. Enable it in Settings to scan your library."
        #else
        "Photo access is off. Enable it in System Settings to scan your library."
        #endif
    }()

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
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
                Text(Self.settingsHint)
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

    private func openSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #else
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Album picker

struct AlbumPickerSheet: View {
    let albums: [AlbumOption]
    let isLoading: Bool
    let personalCount: Int
    let sharedCount: Int
    let scope: ScanScope
    let onSelect: (ScanScope) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Splitting by source only means anything in a library that holds both. A Mac
    /// on an iCloud Shared Library is all shared, a plain iPhone is all personal —
    /// either way the extra rows would just restate "Entire library".
    private var isMixedLibrary: Bool { personalCount > 0 && sharedCount > 0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "Entire library",
                        count: isMixedLibrary ? personalCount + sharedCount : nil,
                        isSelected: scope == .entireLibrary) {
                        onSelect(.entireLibrary); dismiss()
                    }
                    if isMixedLibrary {
                        row(title: "Personal library", count: personalCount,
                            isSelected: scope == .personal) {
                            onSelect(.personal); dismiss()
                        }
                        row(title: "Shared library", count: sharedCount,
                            isSelected: scope == .shared) {
                            onSelect(.shared); dismiss()
                        }
                    }
                }
                if isLoading {
                    Section("Albums") {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Counting your albums…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums) { album in
                            row(title: album.title, count: album.count,
                                isSelected: scope == .album(album.id)) {
                                onSelect(.album(album.id)); dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan scope")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 420)
        #endif
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
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - About

struct AboutContent: View {
    /// One App Store record serves both platforms (universal purchase).
    static let appStoreID = "6770612666"
    static let feedbackEmail = "matranc03+duperemover@gmail.com"

    @Environment(\.openURL) private var openURL

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            icon

            VStack(spacing: 4) {
                Text("Dupe Remover")
                    .font(.title2).fontWeight(.semibold)
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("Finds duplicate and visually similar photos in your library or in any folder you point it at, and moves the extras somewhere recoverable. Everything runs on your device — nothing is uploaded.")
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
                Link(destination: URL(string: "https://github.com/MatRanc/DupeRemover")!) {
                    Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://matranc.github.io/DupeRemover/")!) {
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

    @ViewBuilder
    private var icon: some View {
        #if os(iOS)
        if let icon = UIImage(named: "AboutIcon") {
            Image(platform: icon)
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
        #else
        Image(platform: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 96, height: 96)
        #endif
    }

    private func rateApp() {
        #if os(iOS)
        let scheme = "itms-apps"
        #else
        let scheme = "macappstore"
        #endif
        if let url = URL(string: "\(scheme)://apps.apple.com/app/id\(Self.appStoreID)?action=write-review") {
            openURL(url)
        }
    }

    private func sendFeedback() {
        let subject = "Dupe Remover Feedback"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        if let url = URL(string: "mailto:\(Self.feedbackEmail)?subject=\(encoded)") {
            openURL(url)
        }
    }
}

#if os(iOS)
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { AboutContent() }
                .navigationTitle("About")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
#endif

// MARK: - Match info

struct MatchInfoContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(
                "Identical",
                "Compares photos byte-for-byte. Catches exact duplicates: the same photo saved twice, imported more than once, or copied between folders. Fast and 100% reliable, but won't catch a photo that's been re-saved, resized, or edited — even one changed pixel makes it a different file."
            )
            section(
                "Also match similar photos",
                "Uses Apple's on-device Vision framework to compare what photos look like, not how they're stored. Catches re-exported JPEGs, light edits, the same shot at different resolutions, or screenshots of the same image. Slower the first time because each photo is analyzed once — results are cached so repeat scans are fast."
            )
            section(
                "Similarity slider",
                "How alike two photos have to look before they're grouped. Higher is stricter — at 95% only photos that look almost identical are grouped. Lower catches more edited or cropped variants, at the risk of grouping photos that only resemble each other. 80% works well for most libraries."
            )

            Text("Both modes run entirely on your device. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding()
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
struct MatchInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { MatchInfoContent() }
                .navigationTitle("How matching works")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
#endif
