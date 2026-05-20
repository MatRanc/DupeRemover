import SwiftUI
import QuickLookThumbnailing
import AppKit

struct ContentView: View {
    @StateObject private var vm = ScanViewModel()
    @State private var showingMatchInfo = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 620, minHeight: 540)
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            primaryRow
            matchingRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var primaryRow: some View {
        HStack(spacing: 10) {
            Button {
                vm.chooseFoldersAndScan()
            } label: {
                Label("Choose folder…", systemImage: "folder")
            }
            .disabled(vm.isScanning)

            Button {
                vm.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(vm.lastScannedFolders.isEmpty || vm.isScanning)
            .help(vm.lastScannedFolders.isEmpty
                  ? "No folder scanned yet"
                  : "Rescan: " + vm.lastScannedFolders.map { $0.lastPathComponent }.joined(separator: ", "))

            Spacer(minLength: 8)

            Menu {
                let summary = vm.cacheEntries == 0
                    ? "Cache is empty"
                    : "\(vm.cacheEntries) entries · \(formatBytes(vm.cacheSize))"
                Text(summary)
                Divider()
                Button("Clear cache") {
                    Task { await vm.clearCache() }
                }
                .disabled(vm.cacheEntries == 0)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Cache options")

            Button(role: .destructive) {
                vm.trashSelected()
            } label: {
                Label("Move \(vm.selected.count) to Trash", systemImage: "trash")
            }
            .disabled(vm.selected.isEmpty || vm.isScanning)
            .keyboardShortcut(.delete)
        }
    }

    private var matchingRow: some View {
        HStack(spacing: 10) {
            Toggle("Match similar photos", isOn: $vm.matchSimilar)
                .toggleStyle(.checkbox)
                .disabled(vm.isScanning)
                .fixedSize()

            Button {
                showingMatchInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("How matching works")
            .popover(isPresented: $showingMatchInfo, arrowEdge: .bottom) {
                MatchInfoPopover()
            }

            HStack(spacing: 6) {
                Text("Strictness")
                    .foregroundStyle(.secondary)
                Slider(value: $vm.similarityPercent, in: 5...40, step: 1)
                    .frame(minWidth: 90, idealWidth: 130, maxWidth: 160)
                Text("\(Int(vm.similarityPercent))%")
                    .monospacedDigit()
                    .frame(width: 34, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .disabled(!vm.matchSimilar || vm.isScanning)
            .help("Lower = stricter (only very-similar photos). 20% works well for most cases.")
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button("Select all but first") {
                vm.selectAllButFirstInEveryGroup()
            }
            .disabled(vm.groups.isEmpty || vm.isScanning)
            .fixedSize()

            Button("Clear selection") {
                vm.clearSelection()
            }
            .disabled(vm.selected.isEmpty)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isScanning {
            ProgressView(vm.statusText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text(vm.statusText).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(vm.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            FileRow(
                                file: file,
                                isSelected: vm.selected.contains(file.url)
                            ) { vm.toggle(file.url) }
                        }
                    } header: {
                        groupHeader(for: group)
                    }
                }
            }
        }
    }

    private func groupHeader(for group: DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.mode == .identical ? "Identical" : "Similar")
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    group.mode == .identical
                        ? Color.blue.opacity(0.18)
                        : Color.purple.opacity(0.18)
                )
                .clipShape(Capsule())
            Text("\(group.files.count) photos")
            if group.mode == .identical {
                Text("· \(formatBytes(group.files.first?.size ?? 0)) each")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.subheadline)
    }

    private var statusBar: some View {
        HStack {
            Text(vm.statusText).foregroundStyle(.secondary).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct MatchInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How matching works").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Identical").font(.subheadline).fontWeight(.semibold)
                Text("Compares photos byte-for-byte. Catches exact duplicates: same file copied, renamed, or moved between folders. Fast and 100% reliable, but won't catch any photo that has been re-saved, resized, or edited — even one changed pixel makes it a different file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Also match similar photos").font(.subheadline).fontWeight(.semibold)
                Text("Uses Apple's on-device Vision framework to compare what photos look like, not how they're stored. Catches re-exported JPEGs, light edits, the same shot at different resolutions, or screenshots of the same image. Slower the first time because each photo has to be analyzed once — results are cached so repeat scans are fast.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Strictness slider").font(.subheadline).fontWeight(.semibold)
                Text("Controls how visually close two photos have to be before they're grouped. Lower = stricter (only photos that look almost identical). Higher = looser (catches more edited/cropped variants but risks false matches). 20% works well for most photo libraries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Both modes run entirely on your Mac. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 380)
    }
}

struct FileRow: View {
    let file: ImageFile
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()

            ThumbnailView(url: file.url)
                .frame(width: 56, height: 56)
                .background(Color(nsColor: .quaternaryLabelColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).font(.body)
                Text(file.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(formatBytes(file.size))
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 56, height: 56),
                scale: scale,
                representationTypes: .thumbnail
            )
            let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            self.image = rep?.nsImage
        }
    }
}

#Preview {
    ContentView()
}
