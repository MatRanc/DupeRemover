# Merge DupeRemover (macOS) + DupeRemoveriOS into one multiplatform app

**Date:** 2026-08-04
**Status:** Implemented 2026-08-04

## Problem

Dupe Remover exists as two independently developed codebases with the same
bundle identifier (`com.matranc.duperemover`):

- **`DupeRemover`** (this repo, `PhotoDuplicateFinder/`) — the published
  macOS app. Folder-based scanning (`NSOpenPanel`) plus Photos/iCloud
  library scanning (added recently on `main`). Still on the original
  plist-based cache, which OOMs on large libraries. Has its own small,
  separate in-flight fix for this (`fix/cache-persistence`,
  "Bound cache save cost; drain the encoder's autorelease graph") that
  predates and is narrower than the iOS fix.
- **`DupeRemoveriOS`** — the unreleased iOS app. Photos-library scanning
  only, no folder scanning. Has a much more thorough fix for the same
  class of bug: an append-only cache log plus parallelized, revision-gated
  feature-print comparison, verified end-to-end on a real 46k-photo
  library (no crash, ~5 min vs. ~20 before).

Two copies of the same core logic (cache, scanner, compare) means every
bug fix has to be ported by hand, and already isn't being — the macOS app
is missing the OOM fix entirely and is carrying a smaller, different
attempt at the same problem on a side branch.

## Goal

One Xcode project, one multiplatform App target, one codebase, living in
`DupeRemover` (the published repo). Bring macOS up to iOS's reliability
level. Add local-folder scanning to iOS, using the same shared item model
that already needs to represent "a file or a Photos asset" for macOS.

Explicitly not in scope: changes to the matching algorithm or distance
thresholds; App Store "Universal Purchase" listing linkage (a store-side
config task, independent of the code); persisted security-scoped
bookmarks on either platform (neither app has this today — the mac app
re-prompts `NSOpenPanel` every scan, so iOS matches that rather than
gaining a new capability macOS doesn't have).

## Target structure

A single Xcode project with one App target set to build for two
destinations (iOS 17+, macOS 14+) — Xcode's native "supports multiple
platforms" target, not two separate targets sharing files via membership
checkboxes. Per-destination build settings (entitlements file, Info.plist
keys) are set per-platform on that one target; Xcode supports this
directly (`ENTITLEMENTS_FILE`, `INFOPLIST_KEY_*` etc. can all vary by
`SDKROOT`/platform condition on a single target).

`DupeRemoveriOS` is retired after cutover: its README points to
`DupeRemover`, and the repo is archived. `DupeRemover` keeps its existing
App Store Connect listing, privacy policy, and licensing — none of that
changes since the bundle ID is unchanged.

## Shared item model

Today the two apps solve "what is a scannable thing" differently:

- iOS's `PhotoAsset` (`PhotoLibrary.swift`) is Photos-only. It never
  carries a `PHAsset` across an actor boundary — it keeps a Sendable
  snapshot (`localIdentifier` + cheap metadata: pixel dimensions, mtime,
  byte size) and re-fetches the `PHAsset` only inside the task that needs
  it.
- macOS's `ItemSource` (`Scanner.swift`) already unifies `.file(URL)` and
  `.asset(PHAsset)` under one enum, but carries the raw `PHAsset` directly
  across threads, marked `@unchecked Sendable` without the same
  re-fetch-on-demand discipline iOS uses.

The merge adopts iOS's safer snapshot-and-refetch pattern and extends it
with a `.file(URL)` case, producing one `ScanItem`/`ItemSource` type used
by both platforms:

```swift
nonisolated enum ItemSource: Hashable, Sendable {
    case file(URL)
    case asset(String) // PHAsset.localIdentifier; re-fetch, never carry the PHAsset
}
```

This is the actual unification point: once `Scanner`/`Cache` operate on
this one type, a Photos-library scan and a folder scan are the same code
path on both platforms. iOS's folder scanning is a UI addition (a folder
picker producing `.file` items), not a scanner rewrite. It also resolves
the open question in iOS issue #3 (unverified `@unchecked Sendable`
assumption on `VNFeaturePrintObservation`) for the file case at the same
time, since raw Vision/Photos objects never cross the parallel-compare
worker boundary in this model.

## Cache & Scanner

Port iOS's `Cache.swift` (append-only log, revision gating, legacy plist
migration) and `Scanner.swift` (parallelized comparison with drained
autorelease pools) as the shared implementation for both platforms. This
directly replaces macOS's plist-based cache and its narrower
`fix/cache-persistence` branch — that branch is superseded, not merged
forward. `Tools/CacheSelfTest.swift` moves over as-is and becomes the
shared cache/scanner test target for both platforms.

## Per-platform pieces

- **File access UI** — macOS keeps `NSOpenPanel`; iOS gains
  `UIDocumentPickerViewController` for folder selection. Neither persists
  a security-scoped bookmark; both re-prompt per scan, matching today's
  macOS behavior.
- **Entitlements** — macOS keeps App Sandbox + user-selected
  read-write files + Photos library access. iOS keeps its existing Photos
  usage description; the document picker needs no new entitlement.
- **Views** — platform-specific SwiftUI screens gated by
  `#if os(iOS)` / `#if os(macOS)` only where chrome genuinely differs
  (window-based vs. navigation-stack layout). The group list, strictness
  slider, and progress/ETA view are shared components — `Views.swift`
  (iOS) and `ContentView.swift` (macOS) are already close enough in
  structure that this is a consolidation, not a rewrite.

## Testing

`Tools/CacheSelfTest.swift` runs for both platform destinations. Manual
verification before calling the merge done: a real-library scan on macOS
(folder + Photos library) and on iOS (Photos library + a folder picked
via the new picker), checking for the same no-crash/timing bar the iOS
46k run already met.

## Risks / open questions carried forward

- iOS's own open issues (#2, O(n²) comparison cost; #3, the
  `@unchecked Sendable` Vision assumption) are unaffected by this merge
  and remain separately tracked — the merge doesn't fix or worsen either.
- Converting macOS's `ItemSource.asset(PHAsset)` call sites to the
  snapshot-and-refetch pattern touches more of `Scanner.swift` than a
  typical port; this is the highest-effort single piece of the merge.

## As built

Shipped as 1.1 (build 9). Three deviations from the above:

- **One change token, not two fields.** `ScanItem.token` / `CacheEntry.token`
  holds pixel count for Photos assets and byte size for files, instead of
  the spec's separate `pixelCount`/`size` notions. `CacheEntry` has a
  hand-written `init(from:)` that also decodes the legacy `pixelCount` (iOS)
  and `size` (macOS) keys, so no existing user loses their cache on upgrade.
- **Folder pickers stayed split.** macOS keeps `NSOpenPanel`, iOS uses
  SwiftUI `.fileImporter` (rather than `UIDocumentPickerViewController`
  directly) — per the spec's letter. Consolidating both onto one
  `.fileImporter` is deferred to a tracked issue.
- **Trash on both platforms.** Deleting a local file uses
  `FileManager.trashItem` on iOS as well as macOS; the spec did not say what
  iOS should do with files picked from the document picker.

## Found while testing

Two things the test suite turned up that were not in the design, both fixed:

- **Vision blocked the cooperative thread pool.** `VNImageRequestHandler.perform`
  blocks its caller, and the analyze phase called it straight from an async task.
  Swift's cooperative pool has one thread per core and does not grow to cover
  blocked threads, so four concurrent analyses on a four-core machine parked the
  whole pool and the scan stopped dead — silently, with no crash and no error.
  The call now runs on a private `DispatchQueue` (`visionQueue` in `Scanner.swift`);
  a test that runs four scans at once guards it under a time limit. This was a
  latent hazard in the shipped iOS code too — it only escaped notice because
  phones have more cores than the concurrency cap.
- **`FileManager.trashItem` can fail on iOS.** Locations without a Trash refuse
  the move, and the old status line for that case read "Nothing deleted." It now
  says what happened. Whether a folder picked through the iOS document picker
  supports trashing is still unverified on a real device.
