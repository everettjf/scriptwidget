# Photos API (Runtime 1.4)

<!-- platforms:start -->
> **Runs on:** iPhone and iPad, Mac, Android (Individual photos picked in the app, no albums). **Not on:** Windows, Linux. Details and limits: [Platform support](platform-support.md).
<!-- platforms:end -->

Declare `photos` in Package 2.0. Scripts never receive unrestricted library access. In **ScriptWidget Settings → Photos**, explicitly select up to 24 photos and eight albums. No sources are selected by default, even with full system authorization. The chooser lists at most 64 recent available photos and 32 albums. Limited system access is supported; albums may be unavailable in that mode. Change the system selection in Photos privacy settings and reload the native selection panel.

- `$photos.isAvailable()` reports whether the installed execution can use this API.
- `$photos.authorizationStatus()` returns `authorized`, `limited`, `notDetermined`, `denied`, `restricted`, `unavailable` or `undeclared`. Authorization does not select sources.
- `await $photos.requestAuthorization()` requests the system's read/write Photos authorization in the app; this public API only reads. A widget extension only checks existing authorization; it never presents a prompt. Future timeline and Live Activity presentations only check status.
- `await $photos.items({limit:4,offset:0,maxAgeSeconds:3600})` reads a bounded snapshot from native selected sources. Limit is an integer 1–4, offset 0–63, max age 0–86400 seconds. Unknown options, booleans masquerading as numbers and nonfinite values are rejected.

```jsx
const result = await $photos.items({limit: 4});
if (result.items.length) {
  $render(<image url={result.items[0].image} mode="fit" frame="max"/>);
} else {
  $render(<text>{result.unavailableCount ? "Download photos in Photos first" : "No selected photos"}</text>);
}
```

A result contains `status` (`ready` or `unavailable`), `items`, `unavailableCount`, `fetchedAt`, `source` (`system` or `cache`) and `stale`. Each item contains `id`, `image` (JPEG data URL), `width` and `height` (original asset dimensions). IDs are opaque identifiers, never filesystem paths. The API exposes no filenames, locations or EXIF metadata.

Queries consider at most 64 candidates from the selected photos/albums, deduplicate by byte-exact identifier, exclude hidden/video assets, and order by creation date (newest first, ID tie break). An offset selects a later bounded page; sources beyond the candidate cap are not scanned indefinitely. Each result contains at most four thumbnails, each at most 768×768 pixels and 128 KiB. Pixels are re-encoded without original metadata. Photo reads share the eight-query execution budget.

Only local image data is requested: scripts and widget extensions cannot trigger cloud downloads. Download a cloud-only photo in Photos first, then refresh with `maxAgeSeconds:0`. Unavailable thumbnails are counted separately from empty sources; partial failures are retried after at most 60 seconds of cached display.

The latest private snapshot per owner/query is at most 1 MiB and becomes unusable after 24 hours. Expiry is checked on access, rather than a promise of background disk deletion. Before both cache use and response delivery, runtime checks current package/system authorization, native source selection, asset existence and modification revisions. Revocation, deletion, source changes and edits cannot expose older matching-looking thumbnails. Observed invalidation clears the owner cache. Already delivered WidgetKit snapshots change on the next system refresh. Future timeline entries and Live Activity presentations can only use a matching prepared snapshot, without fetching new image bytes. Open the installed widget in ScriptWidget first. A different query cannot reuse another page's snapshot.

The **Photo Album Rotator** template rotates four prepared photos across six-hour timeline entries. WidgetKit controls actual delivery timing. Existing **Photo Card** remains a separate manual import/crop workflow.

## Web Studio

The browser uses editable sample responses and never opens the native library. The Photos group supports success, empty, denial and unavailable cases; set authorizationStatus to `limited` to model limited access. `photosSelection` is the flattened list of allowed sample asset IDs (not native album identifiers); `[]` selects none. Full JSON can edit this scope, image data URLs, availability counts and snapshots. `photosSnapshotPrepared:false` models a missing future-entry cache. Samples cannot bypass package permission, source scope, query bounds or the shared budget, and never enter exported packages.

The four geometric landscape samples are original artwork drawn by repository code; they represent no personal photos and contain no third-party imagery. Test JPEGs are `Web/preview-engine/test/fixtures/photo-landscape.jpg` and the `photo-landscape-2.jpg` through `photo-landscape-4.jpg` variants. The same pixels are embedded in the API sample catalog. Regenerate the first with `swift Scripts/generate-photo-mock.swift`; pass an output path and variant 1, 2 or 3 for the other palettes. Update the embedded catalog samples when changing these JPEGs.

This implementation still needs physical-device authorization, limited-library changes, actual system widget delivery and extension-memory acceptance. Automated fixtures are not evidence those checks passed.

See Apple's [PhotoKit fetch limits](https://developer.apple.com/documentation/photos/phfetchoptions/fetchlimit) and [cloud-network image options](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed).
