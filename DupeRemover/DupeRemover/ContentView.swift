import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var vm = ScanViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingMatchInfo = false
    @State private var showingAlbumPicker = false
    @State private var showingDeleteConfirm = false
    @State private var showingAbout = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.hasFullOrLimitedAccess {
                    mainContent
                } else {
                    PermissionView(status: vm.authStatus) {
                        Task { await vm.requestAccess() }
                    }
                }
            }
            .navigationTitle("Dupe Remover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .task {
            vm.refreshAuthStatus()
            if vm.hasFullOrLimitedAccess { await vm.loadAlbums() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.refreshAuthStatus() }
        }
        .sheet(isPresented: $showingMatchInfo) { MatchInfoSheet() }
        .sheet(isPresented: $showingAbout) { AboutSheet() }
        .sheet(isPresented: $showingAlbumPicker) {
            AlbumPickerSheet(
                albums: vm.albums,
                selectedID: vm.selectedAlbumID
            ) { vm.selectAlbum($0) }
        }
    }

    // MARK: Main content

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            results
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    showingAlbumPicker = true
                } label: {
                    Label(vm.selectedAlbumTitle ?? "Entire library", systemImage: "photo.stack")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isScanning)

                Spacer()

                Button {
                    Task { await vm.scan() }
                } label: {
                    Label("Scan", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isScanning)
            }

            VStack(spacing: 6) {
                HStack {
                    Toggle(isOn: $vm.matchSimilar) {
                        Text("Match similar photos")
                    }
                    .disabled(vm.isScanning)

                    Button {
                        showingMatchInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 10) {
                    Text("Strictness")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Slider(value: $vm.similarityPercent, in: 5...40, step: 1)
                    Text("\(Int(vm.similarityPercent))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .opacity(vm.matchSimilar ? 1 : 0.4)
                .disabled(!vm.matchSimilar || vm.isScanning)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var results: some View {
        if vm.isScanning {
            VStack(spacing: 14) {
                if !vm.stepText.isEmpty {
                    Text(vm.stepText)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                if let progress = vm.progress {
                    ProgressView(value: progress) {
                        Text(vm.statusText)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                } else {
                    ProgressView()
                    Text(vm.statusText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let eta = vm.etaText {
                    Text(eta)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let hint = vm.hintText {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Label("Keep Dupe Remover open while it scans.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if vm.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 52))
                    .foregroundStyle(.tertiary)
                Text(vm.statusText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                if vm.authStatus == .limited {
                    Text("You've granted access to selected photos only. Scans cover just those.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(vm.groups) { group in
                    Section {
                        ForEach(group.assets) { asset in
                            AssetRow(
                                asset: asset,
                                isSelected: vm.selected.contains(asset.id)
                            ) { vm.toggle(asset.id) }
                        }
                    } header: {
                        groupHeader(for: group)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func groupHeader(for group: DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.mode == .identical ? "Identical" : "Similar")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    group.mode == .identical
                        ? Color.blue.opacity(0.18)
                        : Color.purple.opacity(0.18)
                )
                .clipShape(Capsule())
            Text("\(group.assets.count) photos")
            Spacer()
        }
        .textCase(nil)
        .font(.subheadline)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !vm.groups.isEmpty {
                HStack {
                    Button("Select all but first") {
                        vm.selectAllButFirstInEveryGroup()
                    }
                    .font(.callout)
                    .disabled(vm.isScanning)
                    Spacer()
                    Button("Clear") { vm.clearSelection() }
                        .font(.callout)
                        .disabled(vm.selected.isEmpty)
                }
            }
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Delete \(vm.selected.count) photo\(vm.selected.count == 1 ? "" : "s")",
                      systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(vm.selected.isEmpty || vm.isScanning)
            .confirmationDialog(
                "Move \(vm.selected.count) photo\(vm.selected.count == 1 ? "" : "s") to Recently Deleted?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(vm.selected.count)", role: .destructive) {
                    Task { await vm.deleteSelected() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("They'll stay recoverable in Recently Deleted for about 30 days.")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .opacity(vm.groups.isEmpty ? 0 : 1)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Text(vm.cacheEntries == 0
                     ? "Cache is empty"
                     : "\(vm.cacheEntries) entries · \(formatBytes(vm.cacheSize))")
                Button("Clear cache") {
                    Task { await vm.clearCache() }
                }
                .disabled(vm.cacheEntries == 0)
                Divider()
                Button("How matching works") { showingMatchInfo = true }
                Button("About") { showingAbout = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(vm.isScanning)
        }
    }
}

#Preview {
    ContentView()
}
