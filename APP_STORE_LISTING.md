# App Store Connect, Listing Copy (v1.2, build 4)

Copy-paste fields for the merged macOS + iOS release.

- Bundle ID: `com.matranc.duperemover`
- App Store ID: `6770612666`
- Version: `1.2`, Build: `4`
- Platforms: macOS 14+, iOS/iPadOS 17+ (one target, universal purchase)
- Localization: English (U.S.) only

Character counts below are exact, counted after writing.

---

## App Name (30 max)

```
Dupe Remover
```

**12 chars.** Already the published macOS name, do not change it, the iOS
build ships under the same App Store record.

---

## Subtitle (30 max)

```
Find & Remove Duplicate Photos
```

**30 chars, exactly at the limit.** Unchanged from the macOS listing. It covers `find`, `remove`,
`duplicate` and `photos`, so the keywords field never has to repeat them.

---

## Promotional Text (170 max)

Editable any time without a new build submission.

```
Now on iPhone and iPad as well as Mac. Scan your Photos library, one album, or a folder you pick. Identical and look-alike matching, all on your device.
```

**152 chars.**

---

## Description (4000 max)

First ~3 lines show above the "more" fold.

```
Dupe Remover finds duplicate and near-duplicate photos and helps you clear out the extras. One app for Mac, iPhone, and iPad.

SCAN WHAT YOU WANT
Point it at your Photos library, the whole thing, personal photos only, shared photos only, or a single album, or pick a folder instead. Both sources work the same on every platform. Cancel a scan at any point.

TWO WAYS TO MATCH
Identical, byte-for-byte SHA-256 comparison. Catches the same file copied, renamed, or moved.
Similar, Apple's on-device Vision framework compares what photos look like, not how they're stored. Catches re-exported JPEGs, light edits, the same shot at different resolutions, screenshots of the same image.
A similarity slider sets how alike two photos have to look before they're grouped. 80% works well for most libraries.

SAFE CLEANUP
"Select all but first" keeps one photo per group and selects the rest. Nothing is permanently deleted: files go to the Trash, and library photos go to Recently Deleted, where they stay for about 30 days.

SEE WHY TWO PHOTOS MATCHED
Tap a result for its dimensions, file size, and created/modified dates down to the second, plus which shared album an iCloud photo came from. Photos whose originals live only in iCloud are recognized as that, not reported as errors.

FAST ON REPEAT
Hashes and feature prints are cached on your device, so scanning the same library again finishes quickly. While a scan runs you see which step it's on and roughly how long is left.

PRIVATE
Everything happens on your device. No account, no analytics, no third-party SDKs. On Mac the app ships with no network entitlements, so the system will not let it connect at all.

Requires macOS 14 Sonoma or later, or iOS 17 or later.
```

**1,383 chars** (newlines included, as App Store Connect counts them).
Deliberately short, it reads in well under a minute.

---

## What's New in This Version (4000 max)

```
• Scan your whole Photos library, personal photos only, shared photos only, or a single album.
• Cancel a scan at any point.
• Tap a result to see its size, dimensions, and created/modified dates down to the second, plus which shared album an iCloud photo came from.
• Photos whose originals live only in iCloud are now recognized as that, not reported as scan failures, and they're no longer re-checked on every scan.
• Fixed a scan that could get stuck on a single cloud-shared photo.
```

**~450 chars.**

Previous (1.1):
```
Version 1.1 merges the Mac and iPhone apps into one.

• Dupe Remover is now on iPhone and iPad. Same scan, same matching, same results as the Mac version.
• Scan a local folder on iOS with the system document picker, not just your Photos library.
• Scan your Photos library on Mac, the whole library or one album, alongside folder scanning.
• Per-step progress with a time estimate while a scan runs.
• Rebuilt cache: repeat scans start where the last one left off, survive being interrupted, and use far less memory on large libraries. Caches from earlier versions are carried over automatically.
```

---

## Keywords (100 max, comma-separated, NO spaces after commas)

```
similar,vision,cleaner,storage,space,album,folder,library,images,scan,offline,private,trash,tidy
```

**96 chars.**

The name covers `dupe`/`remover` and the subtitle covers `find`/`remove`/
`duplicate`/`photos`; Apple already indexes those, so they are not repeated
here. `album` and `folder` are new for this release, both scan sources now
exist on both platforms.

---

## URLs

- **Support URL:** `https://github.com/MatRanc/DupeRemover`
- **Marketing URL:** `https://github.com/MatRanc/DupeRemover` (same is fine, or leave blank, it is optional)
- **Privacy Policy URL:** `https://matranc.github.io/DupeRemover/`

The privacy policy source exists in the repo twice, identical byte-for-byte:
`index.md` at the root and `docs/index.md`. The app's About screen already
links to `https://matranc.github.io/DupeRemover/`
(`DupeRemover/DupeRemover/Views.swift`), and the policy's contact line points
at `https://github.com/MatRanc/DupeRemover/issues`.

**Verify before submitting:** confirm that GitHub Pages is switched on for the
repo and that its source branch/folder matches where the policy lives (root vs
`/docs`). Load the URL in a browser and check it renders the policy. That URL
cannot be verified from inside the repo.

---

## Category

- **Primary: Utilities**, matches `LSApplicationCategoryType = public.app-category.utilities` in the project, so the Mac app's Finder category and the store category agree.
- **Secondary: Photo & Video**, recommended. It picks up photo-organisation searches without changing where the app ranks as a utility. Leaving it blank is also valid; nothing in the app depends on it.

---

## Age Rating

Answer **None / No to every question** in the questionnaire. Result: **4+**.

Specifically:
- Violence (cartoon, realistic, sadistic), sexual content, nudity, profanity, crude humour, horror/fear themes, alcohol/tobacco/drug references, mature/suggestive themes, medical or treatment information: **None**.
- Simulated gambling, real gambling, contests: **No**.
- Unrestricted web access: **No**, the app has no browser and no web view.
- User-generated content or messaging: **No**.
- Advertising: **No**.
- In-app purchases: **No**.

---

## App Privacy

Answer **"No"** to *"Do you or your third-party partners collect any data from this app?"*, this is the single answer that produces **Data Not Collected** on the product page. Choosing it means:

- No data types to declare (no identifiers, contacts, usage data, diagnostics, photos, or anything else).
- No tracking, so the App Tracking Transparency section does not apply.
- No third-party partners or SDKs to declare, the app links only Apple frameworks.

This matches `DupeRemover/DupeRemover/PrivacyInfo.xcprivacy`, which declares
`NSPrivacyTracking = false`, an empty `NSPrivacyCollectedDataTypes`, and one
accessed-API entry: file timestamps, reason `3B52.1` (used to tell whether a
file changed since it was last cached).

**Export compliance:** `ITSAppUsesNonExemptEncryption = NO` is already set in
the project, so App Store Connect will not ask again.

---

## Copyright

```
2026 Mathieu Rancourt
```

Matches `NSHumanReadableCopyright` in the project ("Copyright © 2026 Mathieu
Rancourt. All rights reserved."). App Store Connect wants year + owner only,
without the © symbol.

---

## Review Notes (App Review Information → Notes)

```
No account or sign-in is required. Nothing is gated.

To test: launch the app, choose "Photos Library" or "Local Folder", turn on "Match similar photos" if you want look-alike matching, and start a scan. Any photo saved twice, or a folder containing a copied image file, is enough to produce a group.

The app is fully on-device. It contains no networking code and links no third-party SDKs. The macOS build ships with no network entitlements.
```

---

## Screenshots needed

Up to 10 per size. Portrait for iPhone (the app is portrait-only on iPhone);
iPad supports both orientations, so pick one and stay consistent.

**iPhone, required.** 6.9" display: 1290 × 2796 or 1320 × 2868 px.
(A 6.5" set at 1242 × 2688 or 1284 × 2778 is still accepted as an alternative;
uploading the 6.9" set is the simpler path.)

**iPad, required**, because the build targets iPhone and iPad
(`TARGETED_DEVICE_FAMILY = 1,2`). 13" display: 2064 × 2752 portrait or
2752 × 2064 landscape. (12.9" at 2048 × 2732 / 2732 × 2048 is also accepted.)

**Mac, required.** One of 1280 × 800, 1440 × 900, 2560 × 1600, or
2880 × 1800 px.

What each shot should show (same story on all three platforms):

1. **Start screen**, the Photos Library / Local Folder segmented picker, the Identical and Similar toggles, and the similarity slider at 80%.
2. **Album picker**, the sheet listing albums, showing a scan scoped to one album.
3. **Scan in progress**, the step line ("Step 2 of 4 · …"), the progress bar, and the "about … left" estimate.
4. **Results**, duplicate groups with thumbnails and the group header, with "Select all but first" visible.
5. **After deleting**, the status line stating the items are recoverable from the Trash or Recently Deleted.
6. **Mac only, optional**, a folder scan's results, where each row shows its path, file size, and the button that reveals it in Finder.

Screenshots must be real captures of the shipping build. No device frames with
added marketing text is the simplest route and matches the app's tone.

---

## Still to decide / supply

- Price tier (free or paid). If paid, decide whether to mention universal purchase in the description, nothing in the current copy claims a price.
- Whether GitHub Pages is actually live at `https://matranc.github.io/DupeRemover/`.
- Whether to set a secondary category or leave it blank.
- The screenshots themselves, plus an optional app preview video (`demo.mp4` in the repo is a Mac recording and would need re-cutting to Apple's preview specs).
