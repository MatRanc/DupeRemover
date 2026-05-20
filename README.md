# Dupe Remover

Duplicate Photo Finder and Remover — a native macOS app that finds duplicate and visually similar photos in any folder you point it at, and lets you move the extras to the Trash.

Everything runs locally on your Mac. Nothing is uploaded.

## Features

- **Identical detection** — byte-for-byte SHA-256 comparison. Catches the same file copied, renamed, or moved between folders.
- **Similar detection** — uses Apple's on-device Vision framework to compare what photos look like, not how they're stored. Catches re-exported JPEGs, light edits, the same shot at different resolutions, screenshots of the same image.
- **Strictness slider** — tune how visually close two photos have to be before they're grouped (5–40%). 20% is a good default.
- **Smart caching** — feature prints and hashes are cached on disk so repeat scans are fast.
- **One-click cleanup** — "Select all but first" picks one keeper per group; the rest move to Trash on the next click.
- **Sandboxed** — App Sandbox + Hardened Runtime, no network entitlements, only the folders you grant access to.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel Mac

## Building from source

1. Clone the repo and open `PhotoDuplicateFinder/PhotoDuplicateFinder.xcodeproj` in Xcode 15 or newer.
2. Select the `PhotoDuplicateFinder` scheme and a Mac destination.
3. Press `⌘R` to build and run.

## Screenshots

_Screenshots go here — see the GitHub repo for previews._

## Credits

- App icon: [Flaticon — duplicate icon](https://www.flaticon.com/free-icon/duplicate_3991529)

## License

[MIT](LICENSE).

---

Source: [github.com/MatRanc/PhotoDuplicateFinder](https://github.com/MatRanc/PhotoDuplicateFinder)
