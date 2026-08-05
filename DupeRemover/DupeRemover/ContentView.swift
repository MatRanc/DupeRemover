import SwiftUI
import Photos
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = ScanViewModel()
    @State private var showingMatchInfo = false
    @State private var showingAlbumPicker = false
    @State private var showingFolderPicker = false
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDeleteConfirm = false
    @State private var showingAbout = false
    #endif

    // MARK: Shell
    //
    // The only genuinely different chrome: iOS stacks controls above a list with a
    // bottom action bar; macOS puts everything in a window toolbar with a status
    // line underneath. Everything between them is shared.

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle("Dupe Remover")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { cacheMenu }
                }
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
        .sheet(isPresented: $showingAlbumPicker) { albumPicker }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                vm.startFolderScan(urls)
            }
        }
        #else
        VStack(spacing: 0) {
            macToolbar
            Divider()
            results
            Divider()
            statusBar
        }
        .frame(minWidth: 680, minHeight: 560)
        .task {
            vm.refreshAuthStatus()
            if vm.hasFullOrLimitedAccess { await vm.loadAlbums() }
        }
        .sheet(isPresented: $showingAlbumPicker) { albumPicker }
        #endif
    }

    private var albumPicker: some View {
        AlbumPickerSheet(
            albums: vm.albums,
            isLoading: vm.isLoadingAlbums,
            personalCount: vm.personalCount,
            sharedCount: vm.sharedCount,
            scope: vm.scope
        ) { vm.scope = $0 }
    }

    // MARK: Shared controls

    var sourcePicker: some View {
        Picker("Scan", selection: $vm.scanSource) {
            Text("Photos Library").tag(ScanSource.photosLibrary)
            Text("Local Folder").tag(ScanSource.folder)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(vm.isScanning)
    }

    /// The slider reads as "how alike two photos must look", which is the way
    /// round people expect a percentage to work. The model keeps the number the
    /// comparison actually uses: the distance it will tolerate.
    var similarity: Binding<Double> {
        Binding(get: { 100 - vm.tolerancePercent },
                set: { vm.tolerancePercent = 100 - $0 })
    }

    /// Where the user changes which photos this app may see.
    func openPhotoSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Photos")
        else { return }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    /// Starts a scan, or opens the folder picker first when scanning a folder.
    func startScan() {
        switch vm.scanSource {
        case .photosLibrary:
            vm.startLibraryScan()
        case .folder:
            #if os(macOS)
            vm.chooseFoldersAndScan()
            #else
            showingFolderPicker = true
            #endif
        }
    }

    var cacheMenu: some View {
        Menu {
            Text(vm.cacheEntries == 0
                 ? "Cache is empty"
                 : "\(vm.cacheEntries) entries · \(formatBytes(vm.cacheSize))")
            Button("Clear cache") {
                Task { await vm.clearCache() }
            }
            .disabled(vm.cacheEntries == 0)
            #if os(iOS)
            Divider()
            Button("How matching works") { showingMatchInfo = true }
            Button("About") { showingAbout = true }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(vm.isScanning)
    }

    // MARK: Results

    @ViewBuilder
    var results: some View {
        if vm.scanSource == .photosLibrary && !vm.hasFullOrLimitedAccess {
            PermissionView(status: vm.authStatus) {
                Task { await vm.requestAccess() }
            }
        } else if vm.isScanning {
            scanProgress
        } else if vm.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 52))
                    .foregroundStyle(.tertiary)
                Text(vm.statusText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                if vm.authStatus == .limited && vm.scanSource == .photosLibrary {
                    Text("You've granted access to selected photos only. Scans cover just those.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("Open Photos settings", action: openPhotoSettings)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            groupList
        }
    }

    private var groupList: some View {
        List {
            ForEach(vm.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ItemRow(
                            item: item,
                            isSelected: vm.selected.contains(item.id)
                        ) { vm.toggle(item.id) }
                    }
                } header: {
                    groupHeader(for: group)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private var scanProgress: some View {
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

            // Lives with the progress, so it's on screen for every phase rather
            // than only whichever ones remembered to offer a way out.
            Button("Cancel") { vm.cancelScan() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
            #if os(iOS)
            Label("Keep Dupe Remover open while it scans.", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
            Text("\(group.items.count) photos")
            if group.mode == .identical, let size = group.items.first?.byteSize, size > 0 {
                Text("· \(formatBytes(size)) each")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .textCase(nil)
        .font(.subheadline)
    }
}

// MARK: - iOS chrome

#if os(iOS)
extension ContentView {
    var content: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            results
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            sourcePicker

            HStack {
                if vm.scanSource == .photosLibrary {
                    Button {
                        showingAlbumPicker = true
                    } label: {
                        Label(vm.scopeTitle, systemImage: "photo.stack")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isScanning)
                }

                Spacer()

                Button(action: startScan) {
                    Label(vm.scanSource == .folder ? "Choose folder…" : "Scan",
                          systemImage: vm.scanSource == .folder ? "folder" : "sparkle.magnifyingglass")
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
                    Text("Similarity")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Slider(value: similarity, in: 60...95, step: 1)
                    Text("\(Int(similarity.wrappedValue))%")
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
                "Delete \(vm.selected.count) photo\(vm.selected.count == 1 ? "" : "s")?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(vm.selected.count)", role: .destructive) {
                    Task { await vm.deleteSelected() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Library photos stay in Recently Deleted for about 30 days; picked files go to the Trash.")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .opacity(vm.groups.isEmpty ? 0 : 1)
    }
}
#endif

// MARK: - macOS chrome

#if os(macOS)
extension ContentView {
    var macToolbar: some View {
        VStack(spacing: 10) {
            primaryRow
            matchingRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var primaryRow: some View {
        HStack(spacing: 10) {
            sourcePicker
                .fixedSize()

            // Scope first, then the button that acts on it: you pick what to scan
            // before you scan it.
            if vm.scanSource == .photosLibrary {
                Button {
                    showingAlbumPicker = true
                } label: {
                    Label(vm.scopeTitle, systemImage: "rectangle.stack")
                        .lineLimit(1)
                }
                .disabled(vm.isScanning)
                .help("Choose which photos to scan")
            }

            Button(action: startScan) {
                vm.scanSource == .folder
                    ? Label("Choose folder…", systemImage: "folder")
                    : Label("Scan", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(vm.isScanning
                      || (vm.scanSource == .photosLibrary && !vm.hasFullOrLimitedAccess))

            // Only the folder source needs this: "Scan" already rescans,
            // whereas "Choose folder…" would make you pick the same folder again.
            if vm.scanSource == .folder, !vm.lastScannedFolders.isEmpty {
                Button {
                    vm.startRescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(vm.isScanning)
                .help("Rescan " + vm.lastScannedFolders.map { $0.lastPathComponent }
                        .joined(separator: ", "))
            }

            Spacer(minLength: 8)

            cacheMenu
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Cache options")

            Button(role: .destructive) {
                Task { await vm.deleteSelected() }
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
                MatchInfoContent().frame(width: 380)
            }

            HStack(spacing: 6) {
                Text("Similarity")
                    .foregroundStyle(.secondary)
                Slider(value: similarity, in: 60...95, step: 1)
                    .frame(minWidth: 90, idealWidth: 130, maxWidth: 160)
                Text("\(Int(similarity.wrappedValue))%")
                    .monospacedDigit()
                    .frame(width: 34, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .disabled(!vm.matchSimilar || vm.isScanning)
            .help("How alike two photos have to look before they're grouped. Higher is stricter; 80% works well for most libraries.")
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

    var statusBar: some View {
        HStack {
            Text(vm.statusText).foregroundStyle(.secondary).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
#endif

#Preview {
    ContentView()
}
