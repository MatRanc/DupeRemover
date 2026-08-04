# Dupe Remover

Duplicate Photo Finder and Remover — a native app for macOS and iOS that finds duplicate and visually similar photos in your Photos library or in any folder you point it at, and lets you clear out the extras.

One app, one codebase, both platforms. Everything runs locally on your device. Nothing is uploaded.

## Features

- **Two scan sources** — scan your Photos library (optionally scoped to a single album) or a local folder you pick yourself. Both work on macOS and iOS.
- **Identical detection** — byte-for-byte SHA-256 comparison. Catches the same file copied, renamed, or moved between folders.
- **Similar detection** — uses Apple's on-device Vision framework to compare what photos look like, not how they're stored. Catches re-exported JPEGs, light edits, the same shot at different resolutions, screenshots of the same image.
- **Strictness slider** — tune how visually close two photos have to be before they're grouped (5–40%). 20% is a good default.
- **Progress and ETA** — per-step progress while scanning, so you know what it's doing and roughly how long is left.
- **Smart caching** — hashes and feature prints are cached on disk so repeat scans are fast. The cache is an append-only log: it survives being killed mid-scan and doesn't blow up memory on large libraries. Caches written by the older macOS or iOS apps are migrated automatically.
- **One-click cleanup** — "Select all but first" picks one keeper per group; the rest go on the next click.
- **Nothing is permanently deleted** — local files go to the Trash, Photos assets go to Recently Deleted.
- **Private by design** — fully on-device, no network entitlements, no analytics.

## Requirements

- macOS 14 Sonoma or later, or iOS 17 or later
- Xcode 16 or newer to build from source (the project uses filesystem-synchronized groups)

## Building from source

1. Clone the repo and open `DupeRemover/DupeRemover.xcodeproj` in Xcode 16 or newer.
2. Select the `DupeRemover` scheme and either a Mac destination or an iOS device/simulator — the one target builds for both.
3. Press `⌘R` to build and run.

### Self-checks

The cache and the folder scanner each have a standalone check you can run
without Xcode (both are macOS-only, and neither needs a test target):

```sh
swiftc -parse-as-library DupeRemover/DupeRemover/Cache.swift \
    Tools/CacheSelfTest.swift -o /tmp/cachecheck && /tmp/cachecheck

swiftc -parse-as-library DupeRemover/DupeRemover/Cache.swift \
    DupeRemover/DupeRemover/ScanItem.swift \
    DupeRemover/DupeRemover/PhotoLibrary.swift \
    DupeRemover/DupeRemover/FileSource.swift \
    Tools/FileSourceSelfTest.swift -o /tmp/filecheck && /tmp/filecheck
```

## Screenshots

_Screenshots go here — see the GitHub repo for previews._

## Credits

- App icon: [Flaticon — duplicate icon](https://www.flaticon.com/free-icon/duplicate_3991529)

## License

[MIT](LICENSE).

---

Source: [github.com/MatRanc/DupeRemover](https://github.com/MatRanc/DupeRemover)
